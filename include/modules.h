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
#ifndef PG_TLE_MODULES_H
#define PG_TLE_MODULES_H

#include "postgres.h"
#include "fmgr.h"
#include "utils/guc.h"
#include "nodes/pg_list.h"
#include "storage/lwlock.h"

#define PG_TLE_MODULES_NSPNAME           "pgtle"
#define PG_TLE_MODULES_TABLENAME         "modules"
#define PG_TLE_MODULES_MAX_NAME_LEN      64
#define PG_TLE_MODULES_MAX_VER_LEN       32
#define PG_TLE_MODULES_SHMEM_NAME        "pgtle_modules"
#define PG_TLE_MODULES_SHMEM_MAX_ENTRIES 256
#define PG_TLE_MODULES_SHMEM_POOL_SIZE   (4 * 1024 * 1024)

typedef enum PgtleModuleCacheMode
{
	PGTLE_MODULE_CACHE_SPI = 0,
	PGTLE_MODULE_CACHE_SHARED = 1
} PgtleModuleCacheMode;

extern int	pgtle_module_cache_mode;

typedef struct PgtleModuleShmemKey
{
	char		module_name[PG_TLE_MODULES_MAX_NAME_LEN];
	char		version[PG_TLE_MODULES_MAX_VER_LEN];
} PgtleModuleShmemKey;

typedef struct PgtleModuleShmemEntry
{
	PgtleModuleShmemKey key;
	bool		is_trusted;
	size_t		source_len;
	size_t		bytecode_len;
	size_t		source_offset;
	size_t		bytecode_offset;
	uint64		access_count;
} PgtleModuleShmemEntry;

typedef struct PgtleModulesSharedState
{
	LWLock	   *lock;
	uint64		epoch;
	int			num_entries;
	size_t		pool_used;
	PgtleModuleShmemEntry entries[PG_TLE_MODULES_SHMEM_MAX_ENTRIES];
	char		pool[PG_TLE_MODULES_SHMEM_POOL_SIZE];
} PgtleModulesSharedState;

/* Lifecycle and Init */
void		pgtle_modules_init(void);
void		pgtle_modules_fini(void);

/* SQL API declarations */
Datum		pg_tle_install_module(PG_FUNCTION_ARGS);
Datum		pg_tle_uninstall_module(PG_FUNCTION_ARGS);
Datum		pg_tle_get_module_sql(PG_FUNCTION_ARGS);
Datum		pg_tle_available_modules(PG_FUNCTION_ARGS);

/* Public C API for language handlers (PL/V8, PLJS, etc.) */
PGDLLEXPORT bool pg_tle_get_module(const char *module_name,
								   const char *version,
								   char **source_code,
								   bytea **bytecode,
								   List **dependencies,
								   bool *is_trusted);

PGDLLEXPORT char *pg_tle_get_module_source(const char *module_name,
										   const char *version,
										   bool *is_trusted);

PGDLLEXPORT bytea *pg_tle_get_module_bytecode(const char *module_name,
											  const char *version,
											  bool *is_trusted);

PGDLLEXPORT void pg_tle_invalidate_module_cache(const char *module_name,
												const char *version);

#endif							/* PG_TLE_MODULES_H */
