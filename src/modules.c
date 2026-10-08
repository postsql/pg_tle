/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "postgres.h"

#include <ctype.h>

#include "access/htup_details.h"
#include "catalog/namespace.h"
#include "catalog/pg_type.h"
#include "commands/user.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/tuplestore.h"
#include "utils/varlena.h"

#include "compatibility.h"
#include "constants.h"
#include "modules.h"
#include "tleextension.h"

PG_FUNCTION_INFO_V1(pg_tle_install_module);
PG_FUNCTION_INFO_V1(pg_tle_uninstall_module);
PG_FUNCTION_INFO_V1(pg_tle_get_module_sql);
PG_FUNCTION_INFO_V1(pg_tle_available_modules);

int			pgtle_module_cache_mode = PGTLE_MODULE_CACHE_SPI;

static const struct config_enum_entry module_cache_mode_options[] = {
	{"spi", PGTLE_MODULE_CACHE_SPI, false},
	{"shared", PGTLE_MODULE_CACHE_SHARED, false},
	{NULL, 0, false}
};

static PgtleModulesSharedState *modules_shared_state = NULL;

static shmem_startup_hook_type prev_shmem_startup_hook = NULL;
static void modules_shmem_startup(void);

#if (PG_VERSION_NUM >= 150000)
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static void modules_shmem_request(void);
#endif

static Size modules_shared_memsize(void);
static void validate_module_identifier(const char *val, const char *field);
static int	pgtle_compare_semver(const char *a, const char *b);
static bool shared_cache_lookup(const char *module_name, const char *version,
								char **ret_version,
								char **source_code, bytea **bytecode, bool *is_trusted);
static void shared_cache_insert(const char *module_name, const char *version,
								const char *source_code, const bytea *bytecode, bool is_trusted);
static void shared_cache_invalidate(const char *module_name, const char *version);

/*
 * Compare two semantic version strings numerically segment by segment.
 * Pre-release versions (e.g. 1.0.0-alpha) sort lower than normal releases (1.0.0).
 */
static int
pgtle_compare_semver(const char *a, const char *b)
{
	const char *pa = a ? a : "";
	const char *pb = b ? b : "";

	while (*pa != '\0' || *pb != '\0')
	{
		if (*pa == '\0' && *pb == '-')
			return 1;
		if (*pa == '-' && *pb == '\0')
			return -1;

		if (isdigit((unsigned char) *pa) && isdigit((unsigned char) *pb))
		{
			char	   *ea;
			char	   *eb;
			unsigned long va = strtoul(pa, &ea, 10);
			unsigned long vb = strtoul(pb, &eb, 10);

			if (va != vb)
				return (va > vb) ? 1 : -1;
			pa = ea;
			pb = eb;
		}
		else
		{
			if (*pa != *pb)
				return ((unsigned char) *pa > (unsigned char) *pb) ? 1 : -1;
			if (*pa != '\0')
				pa++;
			if (*pb != '\0')
				pb++;
		}

		if (*pa == '.' && *pb == '.')
		{
			pa++;
			pb++;
		}
	}
	return 0;
}

/*
 * Calculate shared memory size required for modules cache
 */
static Size
modules_shared_memsize(void)
{
	return MAXALIGN(sizeof(PgtleModulesSharedState));
}

#if (PG_VERSION_NUM >= 150000)
static void
modules_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();

	RequestNamedLWLockTranche(PG_TLE_MODULES_SHMEM_NAME, 1);
	RequestAddinShmemSpace(modules_shared_memsize());
}
#endif

static void
modules_shmem_startup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	modules_shared_state = (PgtleModulesSharedState *)
		ShmemInitStruct(PG_TLE_MODULES_SHMEM_NAME,
						modules_shared_memsize(),
						&found);

	if (!found)
	{
		memset(modules_shared_state, 0, sizeof(PgtleModulesSharedState));
		modules_shared_state->lock = &(GetNamedLWLockTranche(PG_TLE_MODULES_SHMEM_NAME))->lock;
		modules_shared_state->epoch = 1;
		modules_shared_state->num_entries = 0;
		modules_shared_state->pool_used = 0;
	}
	LWLockRelease(AddinShmemInitLock);
}

void
pgtle_modules_init(void)
{
#if (PG_VERSION_NUM < 150000)
	RequestNamedLWLockTranche(PG_TLE_MODULES_SHMEM_NAME, 1);
	RequestAddinShmemSpace(modules_shared_memsize());
#else
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = modules_shmem_request;
#endif

	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = modules_shmem_startup;

	DefineCustomEnumVariable("pgtle.module_cache_mode",
							 "Sets the caching mechanism for pgtle.modules ('spi' or 'shared').",
							 NULL,
							 &pgtle_module_cache_mode,
							 PGTLE_MODULE_CACHE_SPI,
							 module_cache_mode_options,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);
}

void
pgtle_modules_fini(void)
{
	/* Unhook if necessary */
}

static void
validate_module_identifier(const char *val, const char *field)
{
	size_t		len;
	size_t		i;

	if (val == NULL || val[0] == '\0')
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_tle: \"%s\" cannot be empty", field)));

	len = strlen(val);
	if (len >= PG_TLE_MODULES_MAX_NAME_LEN)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("pg_tle: \"%s\" exceeds maximum length of %d bytes",
						field, PG_TLE_MODULES_MAX_NAME_LEN - 1)));

	for (i = 0; i < len; i++)
	{
		unsigned char c = (unsigned char) val[i];

		if (c <= 32 || c >= 127 || strchr(PG_TLE_QUOTING_RELEVANT_CHARS, c) != NULL)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("pg_tle: \"%s\" contains invalid characters: \"%s\"",
							field, val)));
	}
}

static bool
shared_cache_lookup(const char *module_name, const char *version,
					char **ret_version,
					char **source_code, bytea **bytecode, bool *is_trusted)
{
	int			i;
	int			best_idx = -1;

	if (modules_shared_state == NULL || modules_shared_state->lock == NULL)
		return false;

	LWLockAcquire(modules_shared_state->lock, LW_SHARED);

	for (i = 0; i < modules_shared_state->num_entries; i++)
	{
		PgtleModuleShmemEntry *entry = &modules_shared_state->entries[i];

		if (strcmp(entry->key.module_name, module_name) == 0)
		{
			if (version != NULL && version[0] != '\0')
			{
				if (strcmp(entry->key.version, version) == 0)
				{
					best_idx = i;
					break;
				}
			}
			else
			{
				/*
				 * If version is not specified, pick the latest matching by
				 * semantic version comparison.
				 */
				if (best_idx == -1 ||
					pgtle_compare_semver(entry->key.version,
										 modules_shared_state->entries[best_idx].key.version) > 0)
				{
					best_idx = i;
				}
			}
		}
	}

	if (best_idx >= 0)
	{
		PgtleModuleShmemEntry *entry = &modules_shared_state->entries[best_idx];

		entry->access_count++;
		if (is_trusted)
			*is_trusted = entry->is_trusted;

		if (ret_version)
			*ret_version = pstrdup(entry->key.version);

		if (source_code)
		{
			*source_code = palloc(entry->source_len + 1);
			memcpy(*source_code, &modules_shared_state->pool[entry->source_offset], entry->source_len);
			(*source_code)[entry->source_len] = '\0';
		}

		if (bytecode)
		{
			if (entry->bytecode_len > 0)
			{
				*bytecode = (bytea *) palloc(VARHDRSZ + entry->bytecode_len);
				SET_VARSIZE(*bytecode, VARHDRSZ + entry->bytecode_len);
				memcpy(VARDATA(*bytecode),
					   &modules_shared_state->pool[entry->bytecode_offset],
					   entry->bytecode_len);
			}
			else
				*bytecode = NULL;
		}

		LWLockRelease(modules_shared_state->lock);
		return true;
	}

	LWLockRelease(modules_shared_state->lock);
	return false;
}

static void
shared_cache_insert(const char *module_name, const char *version,
					const char *source_code, const bytea *bytecode, bool is_trusted)
{
	size_t		source_len;
	size_t		bytecode_len;
	size_t		total_needed;
	int			i;
	int			target_idx;

	if (modules_shared_state == NULL || modules_shared_state->lock == NULL)
		return;

	source_len = strlen(source_code);
	bytecode_len = bytecode ? VARSIZE_ANY_EXHDR(bytecode) : 0;
	total_needed = source_len + bytecode_len;

	if (total_needed > PG_TLE_MODULES_SHMEM_POOL_SIZE / 2)
		return;					/* Too large for shared pool */

	LWLockAcquire(modules_shared_state->lock, LW_EXCLUSIVE);

	/* Check if entry already exists */
	target_idx = -1;
	for (i = 0; i < modules_shared_state->num_entries; i++)
	{
		if (strcmp(modules_shared_state->entries[i].key.module_name, module_name) == 0 &&
			strcmp(modules_shared_state->entries[i].key.version, version) == 0)
		{
			target_idx = i;
			break;
		}
	}

	/*
	 * If pool space is insufficient or max entries reached, reset cache
	 */
	if (modules_shared_state->pool_used + total_needed > PG_TLE_MODULES_SHMEM_POOL_SIZE ||
		(target_idx == -1 && modules_shared_state->num_entries >= PG_TLE_MODULES_SHMEM_MAX_ENTRIES))
	{
		modules_shared_state->num_entries = 0;
		modules_shared_state->pool_used = 0;
		modules_shared_state->epoch++;
		target_idx = -1;
	}

	if (target_idx == -1)
	{
		target_idx = modules_shared_state->num_entries++;
	}

	{
		PgtleModuleShmemEntry *entry = &modules_shared_state->entries[target_idx];

		strlcpy(entry->key.module_name, module_name, sizeof(entry->key.module_name));
		strlcpy(entry->key.version, version, sizeof(entry->key.version));
		entry->is_trusted = is_trusted;
		entry->source_len = source_len;
		entry->source_offset = modules_shared_state->pool_used;
		memcpy(&modules_shared_state->pool[entry->source_offset], source_code, source_len);
		modules_shared_state->pool_used += source_len;

		entry->bytecode_len = bytecode_len;
		if (bytecode_len > 0)
		{
			entry->bytecode_offset = modules_shared_state->pool_used;
			memcpy(&modules_shared_state->pool[entry->bytecode_offset],
				   VARDATA_ANY(bytecode), bytecode_len);
			modules_shared_state->pool_used += bytecode_len;
		}
		else
		{
			entry->bytecode_offset = 0;
		}
		entry->access_count = 1;
		modules_shared_state->epoch++;
	}

	LWLockRelease(modules_shared_state->lock);
}

static void
shared_cache_invalidate(const char *module_name, const char *version)
{
	int			i;

	if (modules_shared_state == NULL || modules_shared_state->lock == NULL)
		return;

	LWLockAcquire(modules_shared_state->lock, LW_EXCLUSIVE);

	if (module_name == NULL)
	{
		modules_shared_state->num_entries = 0;
		modules_shared_state->pool_used = 0;
		modules_shared_state->epoch++;
		LWLockRelease(modules_shared_state->lock);
		return;
	}

	for (i = 0; i < modules_shared_state->num_entries;)
	{
		bool		matches = (strcmp(modules_shared_state->entries[i].key.module_name, module_name) == 0);

		if (matches && version != NULL && version[0] != '\0')
			matches = (strcmp(modules_shared_state->entries[i].key.version, version) == 0);

		if (matches)
		{
			modules_shared_state->entries[i] =
				modules_shared_state->entries[modules_shared_state->num_entries - 1];
			modules_shared_state->num_entries--;
			modules_shared_state->epoch++;
		}
		else
		{
			i++;
		}
	}

	LWLockRelease(modules_shared_state->lock);
}

/*
 * SQL Function: pgtle.install_module
 * (name text, version text, source_code text, bytecode bytea, dependencies text[], is_trusted boolean)
 */
Datum
pg_tle_install_module(PG_FUNCTION_ARGS)
{
	char	   *mod_name;
	char	   *mod_vers;
	char	   *source_code;
	bytea	   *bytecode = NULL;
	ArrayType  *dependencies = NULL;
	bool		is_trusted = true;
	int			ret;
	char	   *query;
	Oid			argtypes[6];
	Datum		values[6];
	char		nulls[6] = {' ', ' ', ' ', ' ', ' ', ' '};

	check_is_pgtle_admin();

	if (PG_ARGISNULL(0))
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("\"name\" is a required argument")));
	mod_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	validate_module_identifier(mod_name, "name");

	if (PG_ARGISNULL(1))
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("\"version\" is a required argument")));
	mod_vers = text_to_cstring(PG_GETARG_TEXT_PP(1));
	validate_module_identifier(mod_vers, "version");

	if (PG_ARGISNULL(2))
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("\"source_code\" is a required argument")));
	source_code = text_to_cstring(PG_GETARG_TEXT_PP(2));

	if (!PG_ARGISNULL(3))
		bytecode = PG_GETARG_BYTEA_PP(3);
	else
		nulls[3] = 'n';

	if (!PG_ARGISNULL(4))
		dependencies = PG_GETARG_ARRAYTYPE_P(4);
	else
		nulls[4] = 'n';

	if (!PG_ARGISNULL(5))
		is_trusted = PG_GETARG_BOOL(5);

	query = psprintf(
		"INSERT INTO %s.%s (module_name, version, source_code, bytecode, dependencies, is_trusted) "
		"VALUES ($1, $2, $3, $4, $5, $6) "
		"ON CONFLICT (module_name, version) DO UPDATE SET "
		"  source_code = EXCLUDED.source_code, "
		"  bytecode = EXCLUDED.bytecode, "
		"  dependencies = EXCLUDED.dependencies, "
		"  is_trusted = EXCLUDED.is_trusted",
		quote_identifier(PG_TLE_MODULES_NSPNAME),
		quote_identifier(PG_TLE_MODULES_TABLENAME));

	argtypes[0] = TEXTOID;
	values[0] = CStringGetTextDatum(mod_name);
	argtypes[1] = TEXTOID;
	values[1] = CStringGetTextDatum(mod_vers);
	argtypes[2] = TEXTOID;
	values[2] = CStringGetTextDatum(source_code);
	argtypes[3] = BYTEAOID;
	values[3] = bytecode ? PointerGetDatum(bytecode) : (Datum) 0;
	argtypes[4] = TEXTARRAYOID;
	values[4] = dependencies ? PointerGetDatum(dependencies) : (Datum) 0;
	argtypes[5] = BOOLOID;
	values[5] = BoolGetDatum(is_trusted);

	ret = SPI_connect();
	if (ret != SPI_OK_CONNECT)
		ereport(ERROR, (errcode(ERRCODE_CONNECTION_EXCEPTION),
						errmsg("pg_tle: unable to connect to database via SPI")));

	PG_TRY();
	{
		ret = SPI_execute_with_args(query, 6, argtypes, values, nulls, false, 0);
		if (ret != SPI_OK_INSERT && ret != SPI_OK_UTILITY)
			ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
							errmsg("pg_tle: failed to store module \"%s\" (SPI error %d)",
								   mod_name, ret)));
		SPI_finish();
	}
	PG_CATCH();
	{
		SPI_finish();
		PG_RE_THROW();
	}
	PG_END_TRY();

	/* Invalidate shared cache */
	shared_cache_invalidate(mod_name, mod_vers);

	/* If shared cache mode is active, pre-populate */
	if (pgtle_module_cache_mode == PGTLE_MODULE_CACHE_SHARED)
		shared_cache_insert(mod_name, mod_vers, source_code, bytecode, is_trusted);

	PG_RETURN_BOOL(true);
}

/*
 * SQL Function: pgtle.uninstall_module(name text, version text DEFAULT NULL)
 */
Datum
pg_tle_uninstall_module(PG_FUNCTION_ARGS)
{
	char	   *mod_name;
	char	   *mod_vers = NULL;
	char	   *query;
	int			ret;
	int			deleted = 0;
	Oid			argtypes[2];
	Datum		values[2];
	int			nargs = 1;

	check_is_pgtle_admin();

	if (PG_ARGISNULL(0))
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("\"name\" is a required argument")));
	mod_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	validate_module_identifier(mod_name, "name");

	if (!PG_ARGISNULL(1))
	{
		mod_vers = text_to_cstring(PG_GETARG_TEXT_PP(1));
		validate_module_identifier(mod_vers, "version");
		nargs = 2;
	}

	if (nargs == 1)
	{
		query = psprintf("DELETE FROM %s.%s WHERE module_name = $1",
						 quote_identifier(PG_TLE_MODULES_NSPNAME),
						 quote_identifier(PG_TLE_MODULES_TABLENAME));
		argtypes[0] = TEXTOID;
		values[0] = CStringGetTextDatum(mod_name);
	}
	else
	{
		query = psprintf("DELETE FROM %s.%s WHERE module_name = $1 AND version = $2",
						 quote_identifier(PG_TLE_MODULES_NSPNAME),
						 quote_identifier(PG_TLE_MODULES_TABLENAME));
		argtypes[0] = TEXTOID;
		values[0] = CStringGetTextDatum(mod_name);
		argtypes[1] = TEXTOID;
		values[1] = CStringGetTextDatum(mod_vers);
	}

	ret = SPI_connect();
	if (ret != SPI_OK_CONNECT)
		ereport(ERROR, (errcode(ERRCODE_CONNECTION_EXCEPTION),
						errmsg("pg_tle: unable to connect to database via SPI")));

	PG_TRY();
	{
		ret = SPI_execute_with_args(query, nargs, argtypes, values, NULL, false, 0);
		if (ret != SPI_OK_DELETE)
			ereport(ERROR, (errcode(ERRCODE_DATA_EXCEPTION),
							errmsg("pg_tle: failed to delete module \"%s\"", mod_name)));
		deleted = SPI_processed;
		SPI_finish();
	}
	PG_CATCH();
	{
		SPI_finish();
		PG_RE_THROW();
	}
	PG_END_TRY();

	shared_cache_invalidate(mod_name, mod_vers);

	PG_RETURN_BOOL(deleted > 0);
}

/*
 * SQL Function: pgtle.get_module(name text, version text DEFAULT NULL)
 * RETURNS TABLE (module_name text, version text, source_code text, bytecode bytea, dependencies text[], is_trusted boolean)
 */
Datum
pg_tle_get_module_sql(PG_FUNCTION_ARGS)
{
	char	   *mod_name;
	char	   *mod_vers = NULL;
	char	   *source_code = NULL;
	bytea	   *bytecode = NULL;
	bool		is_trusted = true;
	bool		found = false;
	TupleDesc	tupdesc;
	Datum		values[6];
	bool		nulls[6] = {false, false, false, false, true, false};
	HeapTuple	tuple;

	if (PG_ARGISNULL(0))
		ereport(ERROR, (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						errmsg("\"name\" is a required argument")));
	mod_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	if (!PG_ARGISNULL(1))
		mod_vers = text_to_cstring(PG_GETARG_TEXT_PP(1));

	/* Check shared memory cache if enabled */
	if (pgtle_module_cache_mode == PGTLE_MODULE_CACHE_SHARED)
	{
		found = shared_cache_lookup(mod_name, mod_vers, &mod_vers, &source_code, &bytecode, &is_trusted);
	}

	if (!found)
	{
		char	   *query;
		int			ret;
		Oid			argtypes[2];
		Datum		argvals[2];
		int			nargs = 1;
		MemoryContext oldcontext = CurrentMemoryContext;

		ret = SPI_connect();
		if (ret != SPI_OK_CONNECT)
			ereport(ERROR, (errcode(ERRCODE_CONNECTION_EXCEPTION),
							errmsg("pg_tle: unable to connect to database via SPI")));

		if (mod_vers == NULL || mod_vers[0] == '\0')
		{
			query = psprintf(
				"SELECT module_name, version, source_code, bytecode, dependencies, is_trusted "
				"FROM %s.%s WHERE module_name = $1",
				quote_identifier(PG_TLE_MODULES_NSPNAME),
				quote_identifier(PG_TLE_MODULES_TABLENAME));
			argtypes[0] = TEXTOID;
			argvals[0] = CStringGetTextDatum(mod_name);
		}
		else
		{
			query = psprintf(
				"SELECT module_name, version, source_code, bytecode, dependencies, is_trusted "
				"FROM %s.%s WHERE module_name = $1 AND version = $2 LIMIT 1",
				quote_identifier(PG_TLE_MODULES_NSPNAME),
				quote_identifier(PG_TLE_MODULES_TABLENAME));
			argtypes[0] = TEXTOID;
			argvals[0] = CStringGetTextDatum(mod_name);
			argtypes[1] = TEXTOID;
			argvals[1] = CStringGetTextDatum(mod_vers);
			nargs = 2;
		}

		PG_TRY();
		{
			ret = SPI_execute_with_args(query, nargs, argtypes, argvals, NULL, true, 0);
			if (ret == SPI_OK_SELECT && SPI_processed > 0)
			{
				SPITupleTable *tuptable = SPI_tuptable;
				TupleDesc	spi_tupdesc = tuptable->tupdesc;
				uint64		best_row = 0;
				char	   *best_ver = NULL;
				uint64		r;
				bool		isnull;
				Datum		d;
				HeapTuple	spi_tup;

				for (r = 0; r < SPI_processed; r++)
				{
					char   *cand_ver = SPI_getvalue(tuptable->vals[r], spi_tupdesc, 2);

					if (best_ver == NULL ||
						(cand_ver != NULL && pgtle_compare_semver(cand_ver, best_ver) > 0))
					{
						best_ver = cand_ver;
						best_row = r;
					}
				}

				spi_tup = tuptable->vals[best_row];
				found = true;
				MemoryContextSwitchTo(oldcontext);

				d = SPI_getbinval(spi_tup, spi_tupdesc, 2, &isnull);
				if (!isnull)
					mod_vers = TextDatumGetCString(d);

				d = SPI_getbinval(spi_tup, spi_tupdesc, 3, &isnull);
				if (!isnull)
					source_code = TextDatumGetCString(d);

				d = SPI_getbinval(spi_tup, spi_tupdesc, 4, &isnull);
				if (!isnull)
				{
					bytea	   *b = DatumGetByteaPP(d);
					Size		bsz = VARSIZE_ANY(b);

					bytecode = (bytea *) palloc(bsz);
					memcpy(bytecode, b, bsz);
				}

				d = SPI_getbinval(spi_tup, spi_tupdesc, 6, &isnull);
				if (!isnull)
					is_trusted = DatumGetBool(d);
			}
			SPI_finish();
		}
		PG_CATCH();
		{
			SPI_finish();
			PG_RE_THROW();
		}
		PG_END_TRY();

		if (found && pgtle_module_cache_mode == PGTLE_MODULE_CACHE_SHARED && source_code)
		{
			shared_cache_insert(mod_name, mod_vers ? mod_vers : "latest",
								source_code, bytecode, is_trusted);
		}
	}

	if (fcinfo->resultinfo != NULL && IsA(fcinfo->resultinfo, ReturnSetInfo))
	{
		ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

		if (rsinfo->allowedModes & SFRM_Materialize)
		{
			Tuplestorestate *tupstore;
			MemoryContext oldcontext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);

			tupdesc = CreateTupleDescCopy(rsinfo->expectedDesc);
			tupstore = tuplestore_begin_heap(true, false, work_mem);
			rsinfo->returnMode = SFRM_Materialize;
			rsinfo->setResult = tupstore;
			rsinfo->setDesc = tupdesc;
			MemoryContextSwitchTo(oldcontext);

			if (found)
			{
				values[0] = CStringGetTextDatum(mod_name);
				values[1] = CStringGetTextDatum(mod_vers ? mod_vers : "");
				values[2] = source_code ? CStringGetTextDatum(source_code) : (Datum) 0;
				if (!source_code)
					nulls[2] = true;

				values[3] = bytecode ? PointerGetDatum(bytecode) : (Datum) 0;
				if (!bytecode)
					nulls[3] = true;

				values[4] = (Datum) 0;
				nulls[4] = true;

				values[5] = BoolGetDatum(is_trusted);

				tuplestore_putvalues(tupstore, tupdesc, values, nulls);
			}
			return (Datum) 0;
		}
		else if (rsinfo->allowedModes & SFRM_ValuePerCall)
		{
			rsinfo->returnMode = SFRM_ValuePerCall;
			if (!found)
			{
				rsinfo->isDone = ExprEndResult;
				PG_RETURN_NULL();
			}
			rsinfo->isDone = ExprSingleResult;
		}
	}

	if (!found)
		PG_RETURN_NULL();

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("return type must be a row type")));

	tupdesc = BlessTupleDesc(tupdesc);

	values[0] = CStringGetTextDatum(mod_name);
	values[1] = CStringGetTextDatum(mod_vers ? mod_vers : "");
	values[2] = source_code ? CStringGetTextDatum(source_code) : (Datum) 0;
	if (!source_code)
		nulls[2] = true;

	values[3] = bytecode ? PointerGetDatum(bytecode) : (Datum) 0;
	if (!bytecode)
		nulls[3] = true;

	values[4] = (Datum) 0;
	nulls[4] = true;

	values[5] = BoolGetDatum(is_trusted);

	tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}

/*
 * SQL Function: pgtle.available_modules()
 * RETURNS TABLE (module_name text, version text, dependencies text[], is_trusted boolean)
 */
Datum
pg_tle_available_modules(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext oldcontext;
	int			ret;
	char	   *query;
	uint64		j;

	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("set-valued function called in context that cannot accept a set")));

	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("materialize mode required, but it is not allowed in this context")));

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("return type must be a row type")));

	oldcontext = MemoryContextSwitchTo(rsinfo->econtext->ecxt_per_query_memory);
	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;
	MemoryContextSwitchTo(oldcontext);

	ret = SPI_connect();
	if (ret != SPI_OK_CONNECT)
		ereport(ERROR, (errcode(ERRCODE_CONNECTION_EXCEPTION),
						errmsg("pg_tle: unable to connect via SPI")));

	query = psprintf("SELECT module_name, version, dependencies, is_trusted FROM %s.%s ORDER BY module_name, version",
					 quote_identifier(PG_TLE_MODULES_NSPNAME),
					 quote_identifier(PG_TLE_MODULES_TABLENAME));

	ret = SPI_execute(query, true, 0);
	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		SPITupleTable *tuptable = SPI_tuptable;
		TupleDesc	spi_tupdesc = tuptable->tupdesc;

		for (j = 0; j < SPI_processed; j++)
		{
			HeapTuple	spi_tup = tuptable->vals[j];
			Datum		vals[4];
			bool		nls[4];

			vals[0] = SPI_getbinval(spi_tup, spi_tupdesc, 1, &nls[0]);
			vals[1] = SPI_getbinval(spi_tup, spi_tupdesc, 2, &nls[1]);
			vals[2] = SPI_getbinval(spi_tup, spi_tupdesc, 3, &nls[2]);
			vals[3] = SPI_getbinval(spi_tup, spi_tupdesc, 4, &nls[3]);

			tuplestore_putvalues(tupstore, tupdesc, vals, nls);
		}
	}
	SPI_finish();

	return (Datum) 0;
}

/*
 * Public C API: pg_tle_get_module
 */
bool
pg_tle_get_module(const char *module_name,
				  const char *version,
				  char **source_code,
				  bytea **bytecode,
				  List **dependencies,
				  bool *is_trusted)
{
	bool		found = false;

	if (module_name == NULL)
		return false;

	if (pgtle_module_cache_mode == PGTLE_MODULE_CACHE_SHARED)
	{
		found = shared_cache_lookup(module_name, version, NULL, source_code, bytecode, is_trusted);
		if (found)
		{
			if (dependencies)
				*dependencies = NIL;
			return true;
		}
	}

	/* Fall back to SPI query */
	{
		Oid			nspoid;
		int			ret;
		char	   *query;
		Oid			argtypes[2];
		Datum		argvals[2];
		int			nargs = 1;
		char	   *fetched_version = NULL;
		MemoryContext oldcontext = CurrentMemoryContext;

		nspoid = get_namespace_oid(PG_TLE_MODULES_NSPNAME, true);
		if (!OidIsValid(nspoid) ||
			!OidIsValid(get_relname_relid(PG_TLE_MODULES_TABLENAME, nspoid)))
			return false;

		ret = SPI_connect();
		if (ret != SPI_OK_CONNECT)
			return false;

		if (version == NULL || version[0] == '\0')
		{
			query = psprintf(
				"SELECT module_name, version, source_code, bytecode, dependencies, is_trusted "
				"FROM %s.%s WHERE module_name = $1",
				quote_identifier(PG_TLE_MODULES_NSPNAME),
				quote_identifier(PG_TLE_MODULES_TABLENAME));
			argtypes[0] = TEXTOID;
			argvals[0] = CStringGetTextDatum(module_name);
		}
		else
		{
			query = psprintf(
				"SELECT module_name, version, source_code, bytecode, dependencies, is_trusted "
				"FROM %s.%s WHERE module_name = $1 AND version = $2 LIMIT 1",
				quote_identifier(PG_TLE_MODULES_NSPNAME),
				quote_identifier(PG_TLE_MODULES_TABLENAME));
			argtypes[0] = TEXTOID;
			argvals[0] = CStringGetTextDatum(module_name);
			argtypes[1] = TEXTOID;
			argvals[1] = CStringGetTextDatum(version);
			nargs = 2;
		}

		PG_TRY();
		{
			ret = SPI_execute_with_args(query, nargs, argtypes, argvals, NULL, true, 0);
			if (ret == SPI_OK_SELECT && SPI_processed > 0)
			{
				SPITupleTable *tuptable = SPI_tuptable;
				TupleDesc	spi_tupdesc = tuptable->tupdesc;
				uint64		best_row = 0;
				char	   *best_ver = NULL;
				uint64		r;
				HeapTuple	spi_tup;
				bool		isnull;
				Datum		d;

				for (r = 0; r < SPI_processed; r++)
				{
					char   *cand_ver = SPI_getvalue(tuptable->vals[r], spi_tupdesc, 2);

					if (best_ver == NULL ||
						(cand_ver != NULL && pgtle_compare_semver(cand_ver, best_ver) > 0))
					{
						best_ver = cand_ver;
						best_row = r;
					}
				}

				spi_tup = tuptable->vals[best_row];
				found = true;
				MemoryContextSwitchTo(oldcontext);

				d = SPI_getbinval(spi_tup, spi_tupdesc, 2, &isnull);
				if (!isnull)
					fetched_version = TextDatumGetCString(d);

				if (source_code)
				{
					d = SPI_getbinval(spi_tup, spi_tupdesc, 3, &isnull);
					*source_code = isnull ? NULL : TextDatumGetCString(d);
				}

				if (bytecode)
				{
					d = SPI_getbinval(spi_tup, spi_tupdesc, 4, &isnull);
					*bytecode = isnull ? NULL : DatumGetByteaPCopy(d);
				}

				if (dependencies)
					*dependencies = NIL;

				if (is_trusted)
				{
					d = SPI_getbinval(spi_tup, spi_tupdesc, 6, &isnull);
					*is_trusted = isnull ? true : DatumGetBool(d);
				}
			}
			SPI_finish();
		}
		PG_CATCH();
		{
			MemoryContextSwitchTo(oldcontext);
			FlushErrorState();
			SPI_finish();
			found = false;
		}
		PG_END_TRY();

		if (found && pgtle_module_cache_mode == PGTLE_MODULE_CACHE_SHARED && source_code && *source_code)
		{
			shared_cache_insert(module_name,
								(version && version[0]) ? version : (fetched_version ? fetched_version : "latest"),
								*source_code, bytecode ? *bytecode : NULL,
								is_trusted ? *is_trusted : true);
		}
	}

	return found;
}

char *
pg_tle_get_module_source(const char *module_name, const char *version, bool *is_trusted)
{
	char	   *source = NULL;

	if (pg_tle_get_module(module_name, version, &source, NULL, NULL, is_trusted))
		return source;
	return NULL;
}

bytea *
pg_tle_get_module_bytecode(const char *module_name, const char *version, bool *is_trusted)
{
	bytea	   *bc = NULL;

	if (pg_tle_get_module(module_name, version, NULL, &bc, NULL, is_trusted))
		return bc;
	return NULL;
}

void
pg_tle_invalidate_module_cache(const char *module_name, const char *version)
{
	shared_cache_invalidate(module_name, version);
}
