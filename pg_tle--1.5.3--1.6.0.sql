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

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_tle" to load this file. \quit

CREATE TABLE pgtle.modules (
  module_name text NOT NULL,
  version text NOT NULL,
  source_code text NOT NULL,
  bytecode bytea,
  dependencies text[],
  is_trusted boolean NOT NULL DEFAULT true,
  PRIMARY KEY (module_name, version)
);

REVOKE ALL ON pgtle.modules FROM PUBLIC;
GRANT SELECT ON pgtle.modules TO PUBLIC;
GRANT ALL ON pgtle.modules TO pgtle_admin;

CREATE FUNCTION pgtle.install_module
(
  name text,
  version text,
  source_code text,
  bytecode bytea DEFAULT NULL,
  dependencies text[] DEFAULT NULL,
  is_trusted boolean DEFAULT true
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_install_module'
LANGUAGE C;

REVOKE EXECUTE ON FUNCTION pgtle.install_module
(
  name text,
  version text,
  source_code text,
  bytecode bytea,
  dependencies text[],
  is_trusted boolean
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgtle.install_module
(
  name text,
  version text,
  source_code text,
  bytecode bytea,
  dependencies text[],
  is_trusted boolean
) TO pgtle_admin;

CREATE FUNCTION pgtle.uninstall_module
(
  name text,
  version text DEFAULT NULL
)
RETURNS boolean
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_uninstall_module'
LANGUAGE C;

REVOKE EXECUTE ON FUNCTION pgtle.uninstall_module
(
  name text,
  version text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgtle.uninstall_module
(
  name text,
  version text
) TO pgtle_admin;

CREATE FUNCTION pgtle.get_module
(
  name text,
  version text DEFAULT NULL
)
RETURNS TABLE
(
  module_name text,
  version text,
  source_code text,
  bytecode bytea,
  dependencies text[],
  is_trusted boolean
)
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_get_module_sql'
LANGUAGE C STABLE;

REVOKE EXECUTE ON FUNCTION pgtle.get_module
(
  name text,
  version text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgtle.get_module
(
  name text,
  version text
) TO PUBLIC;

CREATE FUNCTION pgtle.available_modules()
RETURNS TABLE
(
  module_name text,
  version text,
  dependencies text[],
  is_trusted boolean
)
SET search_path TO 'pgtle'
AS 'MODULE_PATHNAME', 'pg_tle_available_modules'
LANGUAGE C STABLE;

REVOKE EXECUTE ON FUNCTION pgtle.available_modules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgtle.available_modules() TO PUBLIC;

-- First-Class WebAssembly Engine Bootstrap & Extension Installer (Item 3)
CREATE OR REPLACE FUNCTION pgtle.bootstrap_wasm_engine()
RETURNS void
SET search_path TO 'pgtle, public'
AS $_pgtle_wasm_boot_$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'plv8') THEN
    CREATE EXTENSION plv8;
  END IF;

  IF pg_catalog.to_regclass('public.plv8_wasm_modules') IS NULL THEN
    CREATE TABLE public.plv8_wasm_modules (
      module_name text PRIMARY KEY,
      wasm_bytecode bytea NOT NULL,
      glue_js text,
      installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
    );

    REVOKE ALL ON TABLE public.plv8_wasm_modules FROM PUBLIC;
    GRANT SELECT ON TABLE public.plv8_wasm_modules TO PUBLIC;
    GRANT ALL ON TABLE public.plv8_wasm_modules TO pgtle_admin;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_language WHERE lanname = 'pl/v8-wasm')
     OR COALESCE(pg_catalog.strpos(pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.plv8_wasm_handler()')), 'config.return_mode === ''fixed'''), 0) = 0
  THEN
    CREATE OR REPLACE FUNCTION public.plv8_wasm_bootstrap_polyfills()
  RETURNS void AS $wasm_poly$
    if (typeof globalThis.__plv8_wasm_polyfills_loaded !== 'undefined' &&
        typeof globalThis.__plv8_wasm_create_postgres === 'function') {
      return;
    }

    globalThis.__plv8_wasm_decode_base64 = function(b64) {
      if (typeof b64 !== 'string') {
        throw new Error('pl/v8-wasm: base64 input must be a string');
      }
      const cleaned = b64.replace(/[\r\n\s]+/g, '');
      if (typeof Uint8Array.fromBase64 === 'function') {
        return Uint8Array.fromBase64(cleaned);
      }
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const lookup = new Uint8Array(256);
      lookup.fill(255);
      for (let i = 0; i < alphabet.length; i++) {
        lookup[alphabet.charCodeAt(i)] = i;
      }
      let pad = 0;
      if (cleaned.endsWith('==')) pad = 2;
      else if (cleaned.endsWith('=')) pad = 1;
      const outLen = Math.floor((cleaned.length * 3) / 4) - pad;
      const out = new Uint8Array(outLen);
      let outIdx = 0;
      for (let i = 0; i < cleaned.length; i += 4) {
        const c0 = lookup[cleaned.charCodeAt(i)];
        const c1 = lookup[cleaned.charCodeAt(i + 1)];
        const c2 = cleaned.charCodeAt(i + 2) === 61 ? 0 : lookup[cleaned.charCodeAt(i + 2)];
        const c3 = cleaned.charCodeAt(i + 3) === 61 ? 0 : lookup[cleaned.charCodeAt(i + 3)];
        if (c0 === 255 || c1 === 255 || c2 === 255 || c3 === 255) {
          throw new Error('pl/v8-wasm: invalid base64 character');
        }
        const triple = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
        if (outIdx < outLen) out[outIdx++] = (triple >> 16) & 0xff;
        if (outIdx < outLen) out[outIdx++] = (triple >> 8) & 0xff;
        if (outIdx < outLen) out[outIdx++] = triple & 0xff;
      }
      return out;
    };

    globalThis.__plv8_wasm_hash_bytes = function(bytes) {
      let h1 = 0x811c9dc5 >>> 0;
      let h2 = 0x01000193 >>> 0;
      for (let i = 0; i < bytes.length; i++) {
        h1 = Math.imul(h1 ^ bytes[i], 0x01000193) >>> 0;
        h2 = Math.imul(h2 ^ bytes[i], 0x85ebca6b) >>> 0;
      }
      return bytes.length + ':' + h1.toString(16) + h2.toString(16);
    };

    if (typeof globalThis.TextDecoder === 'undefined') {
      globalThis.TextDecoder = class TextDecoder {
        constructor(label, options) {
          this.encoding = 'utf-8';
          this.fatal = Boolean(options && options.fatal);
          this.ignoreBOM = Boolean(options && options.ignoreBOM);
        }
        decode(input) {
          if (!input) return '';
          const bytes = input instanceof Uint8Array
            ? input
            : (ArrayBuffer.isView(input)
                ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
                : new Uint8Array(input));
          let out = '';
          let i = 0;
          const len = bytes.length;
          while (i < len) {
            const b0 = bytes[i++];
            if (b0 < 0x80) {
              out += String.fromCharCode(b0);
            } else if ((b0 & 0xe0) === 0xc0) {
              const b1 = bytes[i++] & 0x3f;
              out += String.fromCharCode(((b0 & 0x1f) << 6) | b1);
            } else if ((b0 & 0xf0) === 0xe0) {
              const b1 = bytes[i++] & 0x3f;
              const b2 = bytes[i++] & 0x3f;
              out += String.fromCharCode(((b0 & 0x0f) << 12) | (b1 << 6) | b2);
            } else {
              const b1 = bytes[i++] & 0x3f;
              const b2 = bytes[i++] & 0x3f;
              const b3 = bytes[i++] & 0x3f;
              let cp = (((b0 & 0x07) << 18) | (b1 << 12) | (b2 << 6) | b3) - 0x10000;
              out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
            }
          }
          return out;
        }
      };
    }

    if (typeof globalThis.TextEncoder === 'undefined') {
      globalThis.TextEncoder = class TextEncoder {
        constructor() {
          this.encoding = 'utf-8';
        }
        encode(str) {
          str = String(str);
          const buf = [];
          for (let i = 0; i < str.length; i++) {
            let c = str.charCodeAt(i);
            if (c < 0x80) {
              buf.push(c);
            } else if (c < 0x800) {
              buf.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
            } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
              const c2 = str.charCodeAt(i + 1);
              if (c2 >= 0xdc00 && c2 <= 0xdfff) {
                i++;
                const cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
                buf.push(
                  0xf0 | (cp >> 18),
                  0x80 | ((cp >> 12) & 0x3f),
                  0x80 | ((cp >> 6) & 0x3f),
                  0x80 | (cp & 0x3f)
                );
              } else {
                buf.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
              }
            } else {
              buf.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
            }
          }
          return new Uint8Array(buf);
        }
        encodeInto(str, dest) {
          str = String(str);
          let read = 0;
          let written = 0;
          const max = dest.length;
          while (read < str.length) {
            const c = str.charCodeAt(read);
            if (c < 0x80) {
              if (written + 1 > max) break;
              dest[written++] = c;
              read++;
            } else if (c < 0x800) {
              if (written + 2 > max) break;
              dest[written++] = 0xc0 | (c >> 6);
              dest[written++] = 0x80 | (c & 0x3f);
              read++;
            } else if (c >= 0xd800 && c <= 0xdbff && read + 1 < str.length) {
              const c2 = str.charCodeAt(read + 1);
              if (c2 >= 0xdc00 && c2 <= 0xdfff) {
                if (written + 4 > max) break;
                const cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
                dest[written++] = 0xf0 | (cp >> 18);
                dest[written++] = 0x80 | ((cp >> 12) & 0x3f);
                dest[written++] = 0x80 | ((cp >> 6) & 0x3f);
                dest[written++] = 0x80 | (cp & 0x3f);
                read += 2;
              } else {
                if (written + 3 > max) break;
                dest[written++] = 0xe0 | (c >> 12);
                dest[written++] = 0x80 | ((c >> 6) & 0x3f);
                dest[written++] = 0x80 | (c & 0x3f);
                read++;
              }
            } else {
              if (written + 3 > max) break;
              dest[written++] = 0xe0 | (c >> 12);
              dest[written++] = 0x80 | ((c >> 6) & 0x3f);
              dest[written++] = 0x80 | (c & 0x3f);
              read++;
            }
          }
          return { read: read, written: written };
        }
      };
    }

    globalThis.__plv8_wasm_create_wasi = function(getInstance) {
      if (typeof globalThis.__plv8_wasm_create_postgres === 'function') {
        globalThis.postgres = globalThis.__plv8_wasm_create_postgres(getInstance);
      }
      let stderrBuf = '';
      return {
        args_sizes_get: function(argcPtr, argvBufSizePtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          dv.setUint32(argcPtr >>> 0, 0, true);
          dv.setUint32(argvBufSizePtr >>> 0, 0, true);
          return 0;
        },
        args_get: function(_argvPtr, _argvBufPtr) {
          return 0;
        },
        environ_sizes_get: function(environCountPtr, environBufSizePtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          dv.setUint32(environCountPtr >>> 0, 0, true);
          dv.setUint32(environBufSizePtr >>> 0, 0, true);
          return 0;
        },
        environ_get: function(_environPtr, _environBufPtr) {
          return 0;
        },
        clock_res_get: function(_clockId, resPtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          dv.setBigUint64(resPtr >>> 0, 1000n, true);
          return 0;
        },
        clock_time_get: function(_clockId, _precision, timePtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          const ns = BigInt(Math.floor(Date.now() * 1000000));
          dv.setBigUint64(timePtr >>> 0, ns, true);
          return 0;
        },
        fd_write: function(fd, iovsPtr, iovsLen, nwrittenPtr) {
          const inst = getInstance();
          const memBuf = inst.exports.memory.buffer;
          const dv = new DataView(memBuf);
          let total = 0;
          let text = '';
          const dec = new globalThis.TextDecoder('utf-8');
          for (let i = 0; i < (iovsLen >>> 0); i++) {
            const base = (iovsPtr >>> 0) + i * 8;
            const ptr = dv.getUint32(base, true);
            const len = dv.getUint32(base + 4, true);
            if (len > 0 && ptr + len <= memBuf.byteLength) {
              const chunk = new Uint8Array(memBuf, ptr, len);
              total += len;
              if (fd === 1 || fd === 2) {
                text += dec.decode(chunk);
              }
            }
          }
          dv.setUint32(nwrittenPtr >>> 0, total, true);
          if (fd === 2 && text.length > 0) {
            stderrBuf += text;
          }
          return 0;
        },
        fd_read: function(_fd, _iovsPtr, _iovsLen, nreadPtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          dv.setUint32(nreadPtr >>> 0, 0, true);
          return 0;
        },
        fd_close: function(_fd) {
          return 0;
        },
        fd_fdstat_get: function(fd, statPtr) {
          const inst = getInstance();
          const memBuf = inst.exports.memory.buffer;
          if ((statPtr >>> 0) + 24 <= memBuf.byteLength) {
            const u8 = new Uint8Array(memBuf, statPtr >>> 0, 24);
            u8.fill(0);
            if (fd <= 2) {
              u8[0] = 2; // CHARACTER_DEVICE
              return 0;
            }
          }
          return 8; // EBADF
        },
        fd_fdstat_set_flags: function(_fd, _flags) {
          return 0;
        },
        fd_prestat_get: function(_fd, _bufPtr) {
          return 8; // EBADF (terminates Go syscall/fs_wasip1 preopen scan loop)
        },
        fd_prestat_dir_name: function(_fd, _pathPtr, _pathLen) {
          return 8; // EBADF
        },
        fd_seek: function(_fd, _offset, _whence, _newoffsetPtr) {
          return 29; // ESPIPE
        },
        path_open: function() {
          return 44; // ENOENT
        },
        random_get: function(bufPtr, bufLen) {
          const inst = getInstance();
          const u8 = new Uint8Array(inst.exports.memory.buffer, bufPtr >>> 0, bufLen >>> 0);
          for (let i = 0; i < u8.length; i++) {
            u8[i] = (Math.random() * 256) | 0;
          }
          return 0;
        },
        poll_oneoff: function(_inPtr, _outPtr, _nsubscriptions, neventsPtr) {
          const inst = getInstance();
          const dv = new DataView(inst.exports.memory.buffer);
          dv.setUint32(neventsPtr >>> 0, 0, true);
          return 0;
        },
        sched_yield: function() {
          return 0;
        },
        proc_exit: function(code) {
          const msg = stderrBuf ? (': ' + stderrBuf.trim()) : '';
          stderrBuf = '';
          throw new Error('WASM proc_exit(' + code + ')' + msg);
        }
      };
    };

    globalThis.__plv8_wasm_resolve_module = function(modName, modVersion) {
      let cleanName = String(modName || '');
      if (cleanName.startsWith('plv8:')) cleanName = cleanName.slice(5);
      else if (cleanName.startsWith('pgtle:')) cleanName = cleanName.slice(6);
      else if (cleanName.startsWith('tle://')) cleanName = cleanName.slice(6);
      else if (cleanName.startsWith('tle:')) cleanName = cleanName.slice(4);
      let cleanVer = modVersion ? String(modVersion) : null;
      const atIdx = cleanName.indexOf('@', cleanName.startsWith('@') ? 1 : 0);
      if (atIdx > 0) {
        if (!cleanVer) cleanVer = cleanName.slice(atIdx + 1);
        cleanName = cleanName.slice(0, atIdx);
      }

      let untrustedErr = null;
      try {
        const plv8Rows = cleanVer
          ? plv8.execute(
              `SELECT COALESCE(m.package_name, m.path) AS module_name, COALESCE(m.package_version, 'standalone') AS version, m.source AS source_code, m.bytecode, m.is_trusted
               FROM plv8.modules m
               LEFT JOIN plv8.packages p ON p.name = m.package_name AND p.version = m.package_version
               WHERE (m.package_name = $1 AND m.package_version = $2 AND (p.entry_point IS NULL OR m.path = p.entry_point))
                  OR (m.package_name IS NULL AND m.path = $1)
               ORDER BY (pg_catalog.octet_length(m.bytecode) >= 4 AND pg_catalog.substr(m.bytecode, 1, 4) = '\\x0061736d'::bytea) DESC,
                        m.package_name NULLS LAST LIMIT 1`,
              [cleanName, cleanVer]
            )
          : plv8.execute(
              `SELECT COALESCE(m.package_name, m.path) AS module_name, COALESCE(m.package_version, 'standalone') AS version, m.source AS source_code, m.bytecode, m.is_trusted
               FROM plv8.modules m
               LEFT JOIN plv8.packages p ON p.name = m.package_name AND p.version = m.package_version
               WHERE (m.package_name = $1 AND (p.entry_point IS NULL OR m.path = p.entry_point))
                  OR (m.package_name IS NULL AND m.path = $1)
               ORDER BY (pg_catalog.octet_length(m.bytecode) >= 4 AND pg_catalog.substr(m.bytecode, 1, 4) = '\\x0061736d'::bytea) DESC,
                        m.package_version DESC NULLS LAST LIMIT 1`,
              [cleanName]
            );
        if (plv8Rows && plv8Rows.length > 0 && plv8Rows[0].bytecode && plv8Rows[0].bytecode.length >= 8) {
          if (plv8Rows[0].is_trusted === false) {
            const supRows = plv8.execute("SELECT pg_catalog.current_setting('is_superuser') AS is_sup");
            if (!supRows || supRows.length === 0 || supRows[0].is_sup !== 'on') {
              untrustedErr = new Error('pl/v8-wasm: permission denied for untrusted WASM module "' + cleanName + '"');
              throw untrustedErr;
            }
          }
          const bc = plv8Rows[0].bytecode;
          if (bc[0] === 0x00 && bc[1] === 0x61 && bc[2] === 0x73 && bc[3] === 0x6d) {
            const ver = plv8Rows[0].version || 'latest';
            const hash = globalThis.__plv8_wasm_hash_bytes(bc);
            const src = (plv8Rows[0].source_code && plv8Rows[0].source_code.trim().length > 0 && !plv8Rows[0].source_code.trim().startsWith('{'))
              ? plv8Rows[0].source_code
              : null;
            return {
              cacheKey: 'plv8:' + cleanName + ':' + ver + ':' + hash,
              wasmBytes: bc,
              glueSource: src
            };
          }
        }
      } catch (_err) {
        if (untrustedErr) {
          throw untrustedErr;
        }
      }

      try {
        const tleRows = cleanVer
          ? plv8.execute('SELECT module_name, version, source_code, bytecode, is_trusted FROM pgtle.get_module($1, $2)', [cleanName, cleanVer])
          : plv8.execute('SELECT module_name, version, source_code, bytecode, is_trusted FROM pgtle.get_module($1, NULL)', [cleanName]);
        if (tleRows && tleRows.length > 0 && tleRows[0].bytecode && tleRows[0].bytecode.length >= 8) {
          if (tleRows[0].is_trusted === false) {
            const supRows = plv8.execute("SELECT pg_catalog.current_setting('is_superuser') AS is_sup");
            if (!supRows || supRows.length === 0 || supRows[0].is_sup !== 'on') {
              untrustedErr = new Error('pl/v8-wasm: permission denied for untrusted WASM module "' + cleanName + '"');
              throw untrustedErr;
            }
          }
          const bc = tleRows[0].bytecode;
          if (bc[0] === 0x00 && bc[1] === 0x61 && bc[2] === 0x73 && bc[3] === 0x6d) {
            const ver = tleRows[0].version || 'latest';
            const hash = globalThis.__plv8_wasm_hash_bytes(bc);
            const src = (tleRows[0].source_code && tleRows[0].source_code.trim().length > 0 && !tleRows[0].source_code.trim().startsWith('{'))
              ? tleRows[0].source_code
              : null;
            return {
              cacheKey: 'pgtle:' + cleanName + ':' + ver + ':' + hash,
              wasmBytes: bc,
              glueSource: src
            };
          }
        }
      } catch (_err) {
        if (untrustedErr) {
          throw untrustedErr;
        }
      }

      const rows = plv8.execute(
        'SELECT xmin::pg_catalog.text AS xmin, ctid::pg_catalog.text AS ctid, wasm_bytecode, glue_js FROM public.plv8_wasm_modules WHERE module_name = $1',
        [cleanName]
      );
      if (!rows || rows.length === 0 || !rows[0].wasm_bytecode) {
        throw new Error('pl/v8-wasm: module "' + modName + '" not found in plv8.modules, pgtle.modules, or public.plv8_wasm_modules');
      }
      return {
        cacheKey: 'catalog:' + cleanName + ':' + rows[0].xmin + ':' + rows[0].ctid,
        wasmBytes: rows[0].wasm_bytecode,
        glueSource: rows[0].glue_js
      };
    };

    globalThis.__plv8_wasm_invoke = function(instance, glue, exportName, rawArgs, callSpec) {
      const isGlueFn = Boolean(glue && typeof glue[exportName] === 'function');
      const fn = isGlueFn ? glue[exportName] : instance.exports[exportName];
      if (typeof fn !== 'function') {
        throw new Error('pl/v8-wasm: export "' + exportName + '" not found in WASM module');
      }

      if (isGlueFn) {
        return fn.apply(null, rawArgs);
      }

      const argSpecs = callSpec.argSpecs || [];
      const argMode = callSpec.argMode || 'auto';
      const allocExport = callSpec.allocExport || null;
      const freeExport = callSpec.freeExport || null;

      let bufferCount = 0;
      for (let i = 0; i < rawArgs.length; i++) {
        const k = argSpecs[i] || 'auto';
        if (k === 'bytea' || k === 'text' || k === 'custom_buf' ||
            (k === 'auto' && (rawArgs[i] instanceof Uint8Array || typeof rawArgs[i] === 'string'))) {
          bufferCount++;
        }
      }

      let passLenForBuffers = true;
      if (argMode === 'ptr_only' || argMode === 'cstring') {
        passLenForBuffers = false;
      } else if (argMode === 'ptr_len') {
        passLenForBuffers = true;
      } else if (bufferCount > 0 && typeof fn.length === 'number') {
        if (fn.length === rawArgs.length && fn.length < rawArgs.length + bufferCount) {
          passLenForBuffers = false;
        }
      }

      const wasmArgs = [];
      const allocatedPtrs = [];
      let scratchOffset = (typeof callSpec.scratchOffset === 'number')
        ? (callSpec.scratchOffset >>> 0)
        : ((instance.exports.__heap_base && typeof instance.exports.__heap_base.value === 'number')
            ? (instance.exports.__heap_base.value >>> 0)
            : 32768);
      scratchOffset = (scratchOffset + 7) & ~7;

      let allocFn = null;
      let freeFn = null;
      if (allocExport) {
        allocFn = instance.exports[allocExport] || null;
        if (freeExport) {
          freeFn = instance.exports[freeExport] || null;
        } else if (allocExport === 'alloc' && typeof instance.exports.dealloc === 'function') {
          freeFn = instance.exports.dealloc;
        } else if (allocExport === 'malloc' && typeof instance.exports.free === 'function') {
          freeFn = instance.exports.free;
        }
      } else if (typeof instance.exports.alloc === 'function') {
        allocFn = instance.exports.alloc;
        freeFn = freeExport
          ? (instance.exports[freeExport] || null)
          : (typeof instance.exports.dealloc === 'function' ? instance.exports.dealloc : null);
      } else if (typeof instance.exports.malloc === 'function') {
        allocFn = instance.exports.malloc;
        freeFn = freeExport
          ? (instance.exports[freeExport] || null)
          : (typeof instance.exports.free === 'function' ? instance.exports.free : null);
      } else if (typeof instance.exports.__wbindgen_malloc === 'function') {
        allocFn = instance.exports.__wbindgen_malloc;
        freeFn = freeExport
          ? (instance.exports[freeExport] || null)
          : (typeof instance.exports.__wbindgen_free === 'function' ? instance.exports.__wbindgen_free : null);
      }

      try {
        for (let i = 0; i < rawArgs.length; i++) {
          const val = rawArgs[i];
          const kind = argSpecs[i] || 'auto';

          if (kind === 'int8') {
            wasmArgs.push(typeof val === 'bigint' ? val : BigInt(val || 0));
          } else if (kind === 'bool') {
            wasmArgs.push(val ? 1 : 0);
          } else if (kind === 'int2' || kind === 'int4') {
            wasmArgs.push(Number(val) | 0);
          } else if (kind === 'float4' || kind === 'float8') {
            wasmArgs.push(Number(val));
          } else if (kind === 'bytea' || kind === 'text' || kind === 'custom_buf' ||
                     val instanceof Uint8Array || typeof val === 'string') {
            if (!instance.exports.memory) {
              throw new Error('pl/v8-wasm: WASM module must export "memory" to marshal bytea/text buffer arguments');
            }
            const bytes = (val instanceof Uint8Array)
              ? val
              : (ArrayBuffer.isView(val)
                  ? new Uint8Array(val.buffer, val.byteOffset, val.byteLength)
                  : new globalThis.TextEncoder().encode(String(val)));
            const len = bytes.length;
            let ptr = 0;
            if (typeof allocFn === 'function') {
              ptr = allocFn(len + 1, 1) >>> 0;
              allocatedPtrs.push({ ptr: ptr, len: len + 1 });
            } else {
              const needed = scratchOffset + len + 16;
              const curBytes = instance.exports.memory.buffer.byteLength;
              if (needed > curBytes) {
                const addPages = Math.ceil((needed - curBytes) / 65536);
                instance.exports.memory.grow(addPages);
              }
              ptr = scratchOffset;
              scratchOffset = (scratchOffset + len + 9) & ~7;
            }
            const memView = new Uint8Array(instance.exports.memory.buffer);
            if (len > 0) {
              memView.set(bytes, ptr);
            }
            if (ptr + len < memView.byteLength) {
              memView[ptr + len] = 0;
            }
            wasmArgs.push(ptr | 0);
            if (passLenForBuffers) {
              wasmArgs.push(len | 0);
            }
          } else {
            wasmArgs.push(val);
          }
        }

        const rawRes = fn.apply(null, wasmArgs);
        const retKind = callSpec.returnKind || 'scalar';

        if (rawRes === null || rawRes === undefined) {
          return rawRes;
        }

        if (retKind === 'bool') {
          return Boolean(rawRes);
        }

        if (retKind === 'bytea' || retKind === 'text' || retKind === 'custom_buf') {
          if (rawRes instanceof Uint8Array || typeof rawRes === 'string') {
            return rawRes;
          }
          if (!instance.exports.memory) {
            throw new Error('pl/v8-wasm: WASM module must export "memory" to marshal buffer return values');
          }
          const memBuf = instance.exports.memory.buffer;
          let outPtr = 0;
          let outLen = 0;
          const retMode = callSpec.returnMode || 'auto';

          if (Array.isArray(rawRes) && rawRes.length === 2) {
            outPtr = rawRes[0] >>> 0;
            outLen = rawRes[1] >>> 0;
          } else if (typeof rawRes === 'bigint') {
            if (rawRes === 0n) {
              return null;
            }
            if (retMode === 'ptr_len' || retMode === 'ptr_high') {
              outPtr = Number((rawRes >> 32n) & 0xffffffffn) >>> 0;
              outLen = Number(rawRes & 0xffffffffn) >>> 0;
            } else {
              outPtr = Number(rawRes & 0xffffffffn) >>> 0;
              outLen = Number((rawRes >> 32n) & 0xffffffffn) >>> 0;
            }
          } else if (typeof rawRes === 'number') {
            const ptr = rawRes >>> 0;
            if (ptr === 0) {
              return null;
            }
            if (callSpec.returnLength > 0) {
              outPtr = ptr;
              outLen = callSpec.returnLength >>> 0;
            } else if (retMode === 'cstring') {
              outPtr = ptr;
              const u8 = new Uint8Array(memBuf);
              let end = ptr;
              while (end < u8.byteLength && u8[end] !== 0) {
                end++;
              }
              outLen = end - ptr;
            } else {
              if (ptr + 4 > memBuf.byteLength) {
                throw new Error('pl/v8-wasm: returned length-prefixed pointer ' + ptr + ' is out of bounds');
              }
              const dv = new DataView(memBuf);
              outLen = dv.getUint32(ptr, true);
              outPtr = ptr + 4;
            }
          } else {
            throw new Error('pl/v8-wasm: unsupported return value type from WASM buffer function: ' + (typeof rawRes));
          }

          if (outPtr + outLen > memBuf.byteLength) {
            throw new Error(
              'pl/v8-wasm: returned linear memory slice (' + outPtr + ', ' + outLen +
              ') exceeds memory byteLength (' + memBuf.byteLength + ')'
            );
          }

          const outBytes = new Uint8Array(memBuf.slice(outPtr, outPtr + outLen));
          if (retKind === 'text') {
            return new globalThis.TextDecoder('utf-8').decode(outBytes);
          }
          return outBytes;
        }

        return rawRes;
      } finally {
        if (typeof freeFn === 'function' && allocatedPtrs.length > 0) {
          for (let i = 0; i < allocatedPtrs.length; i++) {
            try {
              freeFn(allocatedPtrs[i].ptr, allocatedPtrs[i].len, 1);
            } catch (_ignoreFreeErr) {}
          }
        }
      }
    };

    globalThis.__plv8_wasm_create_postgres = function(getInstance) {
      const spiExecImpl = function(sql) {
        const replacer = function(_k, v) {
          return typeof v === 'bigint' ? Number(v) : v;
        };
        if (typeof sql === 'string') {
          return JSON.stringify(plv8.execute(sql), replacer);
        }
        const inst = getInstance();
        const query = new globalThis.TextDecoder('utf-8').decode(
          new Uint8Array(inst.exports.memory.buffer, sql >>> 0, arguments[1] >>> 0)
        );
        const jsonStr = JSON.stringify(plv8.execute(query), replacer);
        const jsonBytes = new globalThis.TextEncoder().encode(jsonStr);
        if (arguments.length >= 4) {
          const outPtr = arguments[2] >>> 0;
          const outCap = arguments[3] >>> 0;
          if (outCap > 0 && outPtr > 0) {
            const copyLen = Math.min(jsonBytes.length, outCap);
            new Uint8Array(inst.exports.memory.buffer, outPtr, copyLen).set(
              jsonBytes.subarray(0, copyLen)
            );
          }
          return jsonBytes.length | 0;
        }
        if (jsonBytes.length === 0) {
          return 0n;
        }
        const alloc = inst.exports.alloc || inst.exports.malloc || null;
        let ptr = 0;
        if (typeof alloc === 'function') {
          ptr = alloc(jsonBytes.length, 1) >>> 0;
        } else {
          const base = (inst.exports.__heap_base && typeof inst.exports.__heap_base.value === 'number')
            ? (inst.exports.__heap_base.value >>> 0)
            : 49152;
          const needed = base + jsonBytes.length + 16;
          const cur = inst.exports.memory.buffer.byteLength;
          if (needed > cur) {
            inst.exports.memory.grow(Math.ceil((needed - cur) / 65536));
          }
          ptr = base;
        }
        const memView = new Uint8Array(inst.exports.memory.buffer);
        memView.set(jsonBytes, ptr);
        return (BigInt(jsonBytes.length) << 32n) | BigInt(ptr >>> 0);
      };
      return {
        spi_exec: spiExecImpl,
        spi_exec_buf: spiExecImpl,
        elog_notice: function(msg) {
          if (arguments.length >= 2 && typeof msg === 'number') {
            const inst = getInstance();
            const buf = new Uint8Array(inst.exports.memory.buffer, msg >>> 0, arguments[1] >>> 0);
            plv8.elog(NOTICE, new globalThis.TextDecoder('utf-8').decode(buf));
            return;
          }
          plv8.elog(NOTICE, String(msg));
        },
        elog_error: function(msg) {
          if (arguments.length >= 2 && typeof msg === 'number') {
            const inst = getInstance();
            const buf = new Uint8Array(inst.exports.memory.buffer, msg >>> 0, arguments[1] >>> 0);
            throw new Error(new globalThis.TextDecoder('utf-8').decode(buf));
          }
          throw new Error(String(msg));
        }
      };
    };

    globalThis.postgres = {
      spi_exec: function(sql) {
        return JSON.stringify(plv8.execute(String(sql)), function(_k, v) {
          return typeof v === 'bigint' ? Number(v) : v;
        });
      },
      elog_notice: function(msg) {
        plv8.elog(NOTICE, String(msg));
      },
      elog_error: function(msg) {
        throw new Error(String(msg));
      }
    };

    globalThis.__plv8_wasm_polyfills_loaded = true;
  $wasm_poly$ LANGUAGE plv8;

  CREATE OR REPLACE FUNCTION public.plv8_wasm_handler()
  RETURNS language_handler AS $wasm_hdlr$
    if (typeof globalThis.__plv8_wasm_polyfills_loaded === 'undefined' || typeof globalThis.__plv8_wasm_create_postgres !== 'function') {
      plv8.find_function('public.plv8_wasm_bootstrap_polyfills')();
    }

    const rawSrc = arguments[0];
    const meta = arguments[1] || null;
    if (typeof rawSrc !== 'string') {
      throw new Error('pl/v8-wasm: handler must be called with a JSON configuration string');
    }

    let config;
    try {
      config = JSON.parse(rawSrc.trim());
    } catch (e) {
      throw new Error('pl/v8-wasm: function body must be a JSON configuration object: ' + e.message);
    }

    if (!config || typeof config !== 'object' || Array.isArray(config)) {
      throw new Error('pl/v8-wasm: function body must be a JSON object');
    }

    if (typeof config.export !== 'string' || config.export.length === 0) {
      throw new Error('pl/v8-wasm: configuration must specify a non-empty string "export" property');
    }

    const hasModule = typeof config.module === 'string' && config.module.length > 0;
    const hasInlineWasm = typeof config.wasm === 'string' && config.wasm.length > 0;

    if ((hasModule && hasInlineWasm) || (!hasModule && !hasInlineWasm)) {
      throw new Error('pl/v8-wasm: configuration must specify exactly one of "module" or "wasm"');
    }

    function oidToKind(oid, cat) {
      if (oid === 16) return 'bool';
      if (oid === 17) return 'bytea';
      if (oid === 20) return 'int8';
      if (oid === 21) return 'int2';
      if (oid === 23) return 'int4';
      if (oid === 25 || oid === 1043 || oid === 1042) return 'text';
      if (oid === 700) return 'float4';
      if (oid === 701) return 'float8';
      if (cat === 'U') return 'custom_buf';
      return 'scalar';
    }

    const argSpecs = [];
    if (Array.isArray(config.arg_types)) {
      for (let i = 0; i < config.arg_types.length; i++) {
        argSpecs.push(String(config.arg_types[i]));
      }
    } else if (meta && Array.isArray(meta.argtype_oids)) {
      for (let i = 0; i < meta.argtype_oids.length; i++) {
        const cat = (meta.argtype_categories && meta.argtype_categories[i]) || '';
        argSpecs.push(oidToKind(meta.argtype_oids[i], cat));
      }
    }

    let returnKind = 'scalar';
    if (typeof config.return_type === 'string') {
      returnKind = config.return_type;
    } else if (meta && typeof meta.rettype_oid === 'number') {
      returnKind = oidToKind(meta.rettype_oid, meta.rettype_category || '');
    }

    let returnLength = 0;
    if (typeof config.return_length === 'number' && config.return_length > 0) {
      returnLength = config.return_length | 0;
    } else if ((config.return_mode === 'fixed' || config.return_mode === 'raw_ptr') &&
               meta && meta.rettype_category === 'U' && meta.rettype_len > 0) {
      returnLength = meta.rettype_len | 0;
    }

    const callSpec = {
      argSpecs: argSpecs,
      argMode: config.arg_mode || 'auto',
      returnKind: returnKind,
      returnMode: config.return_mode || 'auto',
      returnLength: returnLength,
      allocExport: config.alloc_export || null,
      freeExport: config.free_export || null,
      scratchOffset: (typeof config.scratch_offset === 'number') ? config.scratch_offset : null
    };

    let inlineKey = null;
    if (hasInlineWasm) {
      const bytes = globalThis.__plv8_wasm_decode_base64(config.wasm);
      if (!WebAssembly.validate(bytes)) {
        throw new Error('pl/v8-wasm: inline "wasm" base64 does not contain a valid WebAssembly module');
      }
      inlineKey = 'inline:' + config.export + ':' + globalThis.__plv8_wasm_hash_bytes(bytes);
      if (typeof plv8.compile_wasm_cached === 'function') {
        plv8.compile_wasm_cached(inlineKey, bytes);
      }
    } else if (hasModule && typeof plv8.compile_wasm_cached === 'function') {
      try {
        const resolved = globalThis.__plv8_wasm_resolve_module(config.module, config.version || null);
        if (resolved && resolved.wasmBytes) {
          plv8.compile_wasm_cached(resolved.cacheKey, resolved.wasmBytes);
        }
      } catch (e) {
        if (e && String(e.message || e).indexOf('permission denied for untrusted') !== -1) {
          throw e;
        }
      }
    }

    const exportNameLit = JSON.stringify(config.export);
    const inlineKeyLit = hasInlineWasm ? JSON.stringify(inlineKey) : 'null';
    const moduleNameLit = hasModule ? JSON.stringify(config.module) : 'null';
    const moduleVerLit = (hasModule && config.version) ? JSON.stringify(String(config.version)) : 'null';
    const inlineWasmLit = hasInlineWasm ? JSON.stringify(config.wasm) : 'null';
    const callSpecLit = JSON.stringify(callSpec);

    return `
      if (typeof globalThis.__plv8_wasm_polyfills_loaded === 'undefined' || typeof globalThis.__plv8_wasm_create_postgres !== 'function') {
        plv8.find_function('public.plv8_wasm_bootstrap_polyfills')();
      }
      if (!globalThis._wasm_modules) globalThis._wasm_modules = Object.create(null);
      if (!globalThis._wasm_instances) globalThis._wasm_instances = Object.create(null);
      if (!globalThis._wasm_glues) globalThis._wasm_glues = Object.create(null);

      const exportName = ${exportNameLit};
      const callSpec = ${callSpecLit};
      let cacheKey = ${inlineKeyLit};
      let wasmBytes = null;
      let glueSource = null;

      ${hasModule ? `
        const resolved = globalThis.__plv8_wasm_resolve_module(${moduleNameLit}, ${moduleVerLit});
        cacheKey = resolved.cacheKey;
        if (!globalThis._wasm_instances[cacheKey]) {
          wasmBytes = resolved.wasmBytes;
          glueSource = resolved.glueSource;
        }
      ` : `
        if (!globalThis._wasm_instances[cacheKey]) {
          wasmBytes = globalThis.__plv8_wasm_decode_base64(${inlineWasmLit});
        }
      `}

      if (!globalThis._wasm_instances[cacheKey]) {
        if (!globalThis._wasm_modules[cacheKey]) {
          globalThis._wasm_modules[cacheKey] = (typeof plv8.compile_wasm_cached === 'function')
            ? plv8.compile_wasm_cached(cacheKey, wasmBytes)
            : new WebAssembly.Module(wasmBytes);
        }
        const mod = globalThis._wasm_modules[cacheKey];

        let instance = null;
        const getInst = function() { return instance; };
        const wasi = globalThis.__plv8_wasm_create_wasi(getInst);
        const pgHost = globalThis.__plv8_wasm_create_postgres(getInst);
        const imports = {
          wasi_snapshot_preview1: wasi,
          wasi_unstable: wasi,
          env: {
            abort: function() {
              throw new Error('WASM execution aborted');
            },
            __wasi_fd_write: wasi.fd_write,
            'syscall.seek': function() {
              return 0;
            },
            plv8_elog_notice: function(ptr, len) {
              const buf = new Uint8Array(instance.exports.memory.buffer, ptr >>> 0, len >>> 0);
              plv8.elog(NOTICE, new globalThis.TextDecoder('utf-8').decode(buf));
            },
            plv8_elog_error: function(ptr, len) {
              const buf = new Uint8Array(instance.exports.memory.buffer, ptr >>> 0, len >>> 0);
              throw new Error(new globalThis.TextDecoder('utf-8').decode(buf));
            }
          },
          postgres: pgHost
        };

        if (glueSource) {
          const initGlue = new Function('__raw_wasm', '__raw_imports', glueSource);
          const preGlue = initGlue(null, imports);
          if (preGlue && typeof preGlue.__wbg_get_imports === 'function') {
            const wbgImports = preGlue.__wbg_get_imports();
            const nsKeys = Object.keys(wbgImports);
            for (let i = 0; i < nsKeys.length; i++) {
              const ns = nsKeys[i];
              imports[ns] = Object.assign(imports[ns] || {}, wbgImports[ns]);
            }
          }
          instance = new WebAssembly.Instance(mod, imports);
          if (typeof instance.exports._initialize === 'function') {
            instance.exports._initialize();
          }
          globalThis._wasm_instances[cacheKey] = instance;
          if (preGlue && typeof preGlue.__wbg_set_wasm === 'function') {
            preGlue.__wbg_set_wasm(instance.exports, instance);
            globalThis._wasm_glues[cacheKey] = preGlue.exports || preGlue;
          } else {
            globalThis._wasm_glues[cacheKey] = initGlue(instance.exports, imports);
          }
        } else {
          instance = new WebAssembly.Instance(mod, imports);
          if (typeof instance.exports._initialize === 'function') {
            instance.exports._initialize();
          }
          globalThis._wasm_instances[cacheKey] = instance;
        }
      }

      const instance = globalThis._wasm_instances[cacheKey];
      const glue = globalThis._wasm_glues[cacheKey];

      try {
        return globalThis.__plv8_wasm_invoke(instance, glue, exportName, arguments, callSpec);
      } catch (err) {
        delete globalThis._wasm_instances[cacheKey];
        delete globalThis._wasm_glues[cacheKey];
        throw err;
      }
    `;
  $wasm_hdlr$ LANGUAGE plv8;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_language WHERE lanname = 'pl/v8-wasm') THEN
      CREATE TRUSTED LANGUAGE "pl/v8-wasm"
        HANDLER public.plv8_wasm_handler
        INLINE plv8_inline_handler
        VALIDATOR plv8_call_validator;
    END IF;

    REVOKE ALL ON FUNCTION public.plv8_wasm_handler() FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.plv8_wasm_bootstrap_polyfills() FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION public.plv8_wasm_bootstrap_polyfills() TO PUBLIC;
  END IF;
END;
$_pgtle_wasm_boot_$
LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION pgtle.bootstrap_wasm_engine() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgtle.bootstrap_wasm_engine() TO pgtle_admin;

CREATE OR REPLACE FUNCTION pgtle.install_wasm_extension
(
  name text,
  version text,
  description text,
  wasm_bytecode bytea,
  manifest jsonb DEFAULT NULL,
  ext_sql text DEFAULT NULL,
  requires text[] DEFAULT ARRAY['plv8']::text[]
)
RETURNS boolean
SET search_path TO 'pgtle, public'
AS $_pgtle_wasm_ext_$
DECLARE
  glue_js text := '';
  hex_wasm text;
  gen_sql text := '';
  t_elem jsonb;
  t_schema text;
  t_name text;
  t_len int4;
  t_align text;
  t_storage text;
  t_in_export text;
  t_out_export text;
  t_in_fn text;
  t_out_fn text;
  t_in_cfg jsonb;
  t_out_cfg jsonb;
  op_elem jsonb;
  op_fn_name text;
  op_export text;
  op_nargs int4;
  op_returns text;
  op_sig_args text;
  op_cfg jsonb;
  op_sym text;
  f_elem jsonb;
  f_schema text;
  f_name text;
  f_qual_name text;
  f_export text;
  f_returns text;
  f_vol text;
  f_strict text;
  f_args_sql text;
  f_arg_elem jsonb;
  f_cfg jsonb;
BEGIN
  IF name IS NULL OR pg_catalog.btrim(name) = '' THEN
    RAISE EXCEPTION 'pg_tle: "name" cannot be empty'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF version IS NULL OR pg_catalog.btrim(version) = '' THEN
    RAISE EXCEPTION 'pg_tle: "version" cannot be empty'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF wasm_bytecode IS NULL OR pg_catalog.octet_length(wasm_bytecode) < 8 OR
     pg_catalog.substr(wasm_bytecode, 1, 8) <> '\x0061736d01000000'::bytea THEN
    RAISE EXCEPTION 'pg_tle: wasm_bytecode is not a valid WebAssembly v1 binary (expected \0asm v1 magic header)'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF manifest IS NOT NULL AND manifest ? 'glue_js' AND jsonb_typeof(manifest->'glue_js') = 'string' THEN
    glue_js := manifest->>'glue_js';
  END IF;

  -- Register the WASM module in pgtle.modules immediately (also enforces pgtle_admin check)
  PERFORM pgtle.install_module(name, version, glue_js, wasm_bytecode, NULL, true);

  -- Ensure the shared pl/v8-wasm language and catalog table exist outside CREATE EXTENSION
  PERFORM pgtle.bootstrap_wasm_engine();

  IF pg_catalog.to_regclass('plv8.packages') IS NOT NULL AND pg_catalog.to_regclass('plv8.modules') IS NOT NULL THEN
    INSERT INTO plv8.packages (name, version, entry_point)
    VALUES (install_wasm_extension.name, install_wasm_extension.version, 'index.wasm')
    ON CONFLICT ON CONSTRAINT packages_pkey DO UPDATE SET entry_point = EXCLUDED.entry_point;

    INSERT INTO plv8.modules (path, package_name, package_version, source, bytecode, is_trusted)
    VALUES ('index.wasm', install_wasm_extension.name, install_wasm_extension.version, NULLIF(glue_js, ''), wasm_bytecode, true)
    ON CONFLICT (package_name, package_version, path) WHERE package_name IS NOT NULL DO UPDATE SET
      source = EXCLUDED.source,
      bytecode = EXCLUDED.bytecode,
      is_trusted = EXCLUDED.is_trusted;
  END IF;

  hex_wasm := pg_catalog.encode(wasm_bytecode, 'hex');

  gen_sql := pg_catalog.format(
    $hdr$
SELECT pgtle.bootstrap_wasm_engine();
SELECT pgtle.install_module(%L, %L, %L, pg_catalog.decode(%L, 'hex'), NULL, true);
INSERT INTO plv8.packages (name, version, entry_point)
VALUES (%L, %L, 'index.wasm')
ON CONFLICT (name, version) DO UPDATE SET entry_point = EXCLUDED.entry_point;
INSERT INTO plv8.modules (path, package_name, package_version, source, bytecode, is_trusted)
VALUES ('index.wasm', %L, %L, NULLIF(%L, ''), pg_catalog.decode(%L, 'hex'), true)
ON CONFLICT (package_name, package_version, path) WHERE package_name IS NOT NULL DO UPDATE SET
  source = EXCLUDED.source,
  bytecode = EXCLUDED.bytecode,
  is_trusted = EXCLUDED.is_trusted;
INSERT INTO public.plv8_wasm_modules (module_name, wasm_bytecode, glue_js)
VALUES (%L, pg_catalog.decode(%L, 'hex'), NULLIF(%L, ''))
ON CONFLICT (module_name) DO UPDATE SET
  wasm_bytecode = EXCLUDED.wasm_bytecode,
  glue_js = EXCLUDED.glue_js,
  installed_at = clock_timestamp();
$hdr$,
    name, version, glue_js, hex_wasm,
    name, version,
    name, version, glue_js, hex_wasm,
    name, hex_wasm, glue_js
  );

  -- Process custom WASM-backed base types if declared in manifest->'types'
  IF manifest IS NOT NULL AND manifest ? 'types' AND jsonb_typeof(manifest->'types') = 'array' THEN
    FOR t_elem IN SELECT * FROM pg_catalog.jsonb_array_elements(manifest->'types')
    LOOP
      t_schema := COALESCE(NULLIF(t_elem->>'schema', ''), 'public');
      t_name := COALESCE(NULLIF(t_elem->>'name', ''), NULLIF(t_elem->>'sql_name', ''));
      IF t_name IS NULL OR pg_catalog.btrim(t_name) = '' THEN
        RAISE EXCEPTION 'pg_tle: type entry in manifest must specify "name"'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      t_len := COALESCE((t_elem->>'internallength')::int4, -1);
      t_align := COALESCE(NULLIF(t_elem->>'alignment', ''), 'int4');
      t_storage := COALESCE(NULLIF(t_elem->>'storage', ''), 'plain');
      t_in_export := COALESCE(NULLIF(t_elem->>'input_export', ''), NULLIF(t_elem->>'input_func', ''), NULLIF(t_elem->>'input', ''), t_name || '_in');
      t_out_export := COALESCE(NULLIF(t_elem->>'output_export', ''), NULLIF(t_elem->>'output_func', ''), NULLIF(t_elem->>'output', ''), t_name || '_out');
      t_in_fn := COALESCE(NULLIF(t_elem->>'input_function', ''), t_name || '_in');
      t_out_fn := COALESCE(NULLIF(t_elem->>'output_function', ''), t_name || '_out');

      t_in_cfg := jsonb_build_object(
        'module', name,
        'version', version,
        'export', t_in_export,
        'return_type', 'bytea'
      );
      IF t_len > 0 AND COALESCE((t_elem->>'input_returns_fixed_ptr')::boolean, false) THEN
        t_in_cfg := t_in_cfg || jsonb_build_object('return_length', t_len);
      END IF;
      IF t_elem ? 'input_return_mode' THEN
        t_in_cfg := t_in_cfg || jsonb_build_object('return_mode', t_elem->>'input_return_mode');
      END IF;

      t_out_cfg := jsonb_build_object(
        'module', name,
        'version', version,
        'export', t_out_export,
        'return_type', 'text'
      );
      IF t_elem ? 'output_return_mode' THEN
        t_out_cfg := t_out_cfg || jsonb_build_object('return_mode', t_elem->>'output_return_mode');
      END IF;

      gen_sql := gen_sql || pg_catalog.format(
        $typ$
SELECT pgtle.create_shell_type_if_not_exists(%L, %L);
CREATE OR REPLACE FUNCTION %I.%I(text) RETURNS bytea
LANGUAGE "pl/v8-wasm" IMMUTABLE STRICT AS %L;
CREATE OR REPLACE FUNCTION %I.%I(bytea) RETURNS text
LANGUAGE "pl/v8-wasm" IMMUTABLE STRICT AS %L;
SELECT pgtle.create_base_type_if_not_exists(%L, %L, %L::pg_catalog.regprocedure, %L::pg_catalog.regprocedure, %s, %L, %L);
$typ$,
        t_schema, t_name,
        t_schema, t_in_fn, t_in_cfg::text,
        t_schema, t_out_fn, t_out_cfg::text,
        t_schema, t_name,
        pg_catalog.format('%I.%I(text)', t_schema, t_in_fn),
        pg_catalog.format('%I.%I(bytea)', t_schema, t_out_fn),
        t_len, t_align, t_storage
      );

      -- Process optional WASM operator functions for this base type
      IF t_elem ? 'operators' AND jsonb_typeof(t_elem->'operators') = 'array' THEN
        FOR op_elem IN SELECT * FROM pg_catalog.jsonb_array_elements(t_elem->'operators')
        LOOP
          op_fn_name := COALESCE(
            NULLIF(op_elem->>'name', ''),
            NULLIF(op_elem->>'sql_name', ''),
            NULLIF(op_elem->>'function_name', ''),
            NULLIF(op_elem->>'procedure', ''),
            NULLIF(op_elem->>'func', ''),
            NULLIF(op_elem->>'export', ''),
            NULLIF(op_elem->>'wasm_export', '')
          );
          op_export := COALESCE(
            NULLIF(op_elem->>'export', ''),
            NULLIF(op_elem->>'wasm_export', ''),
            op_fn_name
          );
          op_nargs := COALESCE((op_elem->>'nargs')::int4, 2);
          op_returns := COALESCE(NULLIF(op_elem->>'returns', ''), NULLIF(op_elem->>'result', ''), pg_catalog.format('%I.%I', t_schema, t_name));
          op_sig_args := CASE WHEN op_nargs = 1 THEN 'bytea' ELSE 'bytea, bytea' END;

          op_cfg := jsonb_build_object(
            'module', name,
            'version', version,
            'export', op_export
          );
          IF op_elem ? 'return_length' THEN
            op_cfg := op_cfg || jsonb_build_object('return_length', (op_elem->>'return_length')::int4);
          END IF;
          IF op_elem ? 'return_mode' THEN
            op_cfg := op_cfg || jsonb_build_object('return_mode', op_elem->>'return_mode');
          END IF;
          IF op_elem ? 'arg_mode' THEN
            op_cfg := op_cfg || jsonb_build_object('arg_mode', op_elem->>'arg_mode');
          END IF;

          gen_sql := gen_sql || pg_catalog.format(
            $opfn$
CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s
LANGUAGE "pl/v8-wasm" IMMUTABLE STRICT AS %L;
SELECT pgtle.create_operator_func(%L, %L, %L::pg_catalog.regprocedure);
$opfn$,
            t_schema, op_fn_name, op_sig_args, op_returns, op_cfg::text,
            t_schema, t_name, pg_catalog.format('%I.%I(%s)', t_schema, op_fn_name, op_sig_args)
          );

          op_sym := COALESCE(NULLIF(op_elem->>'operator', ''), NULLIF(op_elem->>'symbol', ''), NULLIF(op_elem->>'op', ''));
          IF op_sym IS NOT NULL THEN
            IF op_nargs = 1 THEN
              gen_sql := gen_sql || pg_catalog.format(
                'CREATE OPERATOR %s (RIGHTARG = %I.%I, PROCEDURE = %I.%I);' || E'\n',
                op_sym, t_schema, t_name, t_schema, op_fn_name
              );
            ELSE
              gen_sql := gen_sql || pg_catalog.format(
                'CREATE OPERATOR %s (LEFTARG = %I.%I, RIGHTARG = %I.%I, PROCEDURE = %I.%I);' || E'\n',
                op_sym, t_schema, t_name, t_schema, t_name, t_schema, op_fn_name
              );
            END IF;
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  -- Process WASM SQL functions if declared in manifest->'functions'
  IF manifest IS NOT NULL AND manifest ? 'functions' AND jsonb_typeof(manifest->'functions') = 'array' THEN
    FOR f_elem IN SELECT * FROM pg_catalog.jsonb_array_elements(manifest->'functions')
    LOOP
      f_schema := NULLIF(f_elem->>'schema', '');
      f_name := COALESCE(NULLIF(f_elem->>'name', ''), NULLIF(f_elem->>'sql_name', ''));
      IF f_name IS NULL OR pg_catalog.btrim(f_name) = '' THEN
        RAISE EXCEPTION 'pg_tle: function entry in manifest must specify "name" or "sql_name"'
          USING ERRCODE = 'invalid_parameter_value';
      END IF;
      IF f_schema IS NOT NULL THEN
        f_qual_name := pg_catalog.format('%I.%I', f_schema, f_name);
      ELSE
        f_qual_name := pg_catalog.format('%I', f_name);
      END IF;

      f_export := COALESCE(NULLIF(f_elem->>'export', ''), NULLIF(f_elem->>'wasm_export', ''), f_name);
      f_returns := COALESCE(NULLIF(f_elem->>'returns', ''), NULLIF(f_elem->>'result', ''), 'int4');
      f_vol := CASE pg_catalog.upper(COALESCE(f_elem->>'volatility', 'IMMUTABLE'))
        WHEN 'VOLATILE' THEN 'VOLATILE'
        WHEN 'STABLE' THEN 'STABLE'
        ELSE 'IMMUTABLE'
      END;
      f_strict := CASE WHEN COALESCE((f_elem->>'strict')::boolean, true) THEN 'STRICT' ELSE '' END;

      f_args_sql := '';
      IF f_elem ? 'args' AND jsonb_typeof(f_elem->'args') = 'array' THEN
        FOR f_arg_elem IN SELECT * FROM pg_catalog.jsonb_array_elements(f_elem->'args')
        LOOP
          IF f_args_sql <> '' THEN
            f_args_sql := f_args_sql || ', ';
          END IF;
          IF jsonb_typeof(f_arg_elem) = 'string' THEN
            f_args_sql := f_args_sql || (f_arg_elem #>> '{}');
          ELSIF jsonb_typeof(f_arg_elem) = 'object' THEN
            IF f_arg_elem ? 'name' AND NULLIF(f_arg_elem->>'name', '') IS NOT NULL THEN
              f_args_sql := f_args_sql || pg_catalog.format('%I %s', f_arg_elem->>'name', f_arg_elem->>'type');
            ELSE
              f_args_sql := f_args_sql || (f_arg_elem->>'type');
            END IF;
          END IF;
        END LOOP;
      END IF;

      f_cfg := jsonb_build_object(
        'module', name,
        'version', version,
        'export', f_export
      );
      IF f_elem ? 'arg_types' THEN
        f_cfg := f_cfg || jsonb_build_object('arg_types', f_elem->'arg_types');
      END IF;
      IF f_elem ? 'arg_mode' THEN
        f_cfg := f_cfg || jsonb_build_object('arg_mode', f_elem->>'arg_mode');
      END IF;
      IF f_elem ? 'return_type' THEN
        f_cfg := f_cfg || jsonb_build_object('return_type', f_elem->>'return_type');
      END IF;
      IF f_elem ? 'return_mode' THEN
        f_cfg := f_cfg || jsonb_build_object('return_mode', f_elem->>'return_mode');
      END IF;
      IF f_elem ? 'return_length' THEN
        f_cfg := f_cfg || jsonb_build_object('return_length', (f_elem->>'return_length')::int4);
      END IF;
      IF f_elem ? 'alloc_export' THEN
        f_cfg := f_cfg || jsonb_build_object('alloc_export', f_elem->>'alloc_export');
      END IF;
      IF f_elem ? 'free_export' THEN
        f_cfg := f_cfg || jsonb_build_object('free_export', f_elem->>'free_export');
      END IF;
      IF f_elem ? 'scratch_offset' THEN
        f_cfg := f_cfg || jsonb_build_object('scratch_offset', (f_elem->>'scratch_offset')::int4);
      END IF;

      gen_sql := gen_sql || pg_catalog.format(
        'CREATE OR REPLACE FUNCTION %s(%s) RETURNS %s LANGUAGE "pl/v8-wasm" %s %s AS %L;' || E'\n',
        f_qual_name, f_args_sql, f_returns, f_vol, f_strict, f_cfg::text
      );
    END LOOP;
  END IF;

  -- Process optional top-level WASM operators if declared in manifest->'operators'
  IF manifest IS NOT NULL AND manifest ? 'operators' AND jsonb_typeof(manifest->'operators') = 'array' THEN
    FOR op_elem IN SELECT * FROM pg_catalog.jsonb_array_elements(manifest->'operators')
    LOOP
      t_schema := COALESCE(NULLIF(op_elem->>'schema', ''), 'public');
      t_name := COALESCE(NULLIF(op_elem->>'type', ''), NULLIF(op_elem->>'leftarg', ''), NULLIF(op_elem->>'rightarg', ''));
      op_fn_name := COALESCE(
        NULLIF(op_elem->>'name', ''),
        NULLIF(op_elem->>'sql_name', ''),
        NULLIF(op_elem->>'function_name', ''),
        NULLIF(op_elem->>'procedure', ''),
        NULLIF(op_elem->>'func', ''),
        NULLIF(op_elem->>'export', ''),
        NULLIF(op_elem->>'wasm_export', '')
      );
      op_export := COALESCE(
        NULLIF(op_elem->>'export', ''),
        NULLIF(op_elem->>'wasm_export', ''),
        op_fn_name
      );
      op_nargs := COALESCE(
        (op_elem->>'nargs')::int4,
        CASE
          WHEN (op_elem ? 'leftarg' AND NOT (op_elem ? 'rightarg')) OR
               (op_elem ? 'rightarg' AND NOT (op_elem ? 'leftarg'))
          THEN 1
          ELSE 2
        END
      );
      op_returns := COALESCE(NULLIF(op_elem->>'returns', ''), NULLIF(op_elem->>'result', ''), pg_catalog.format('%I.%I', t_schema, t_name));
      op_sig_args := CASE WHEN op_nargs = 1 THEN 'bytea' ELSE 'bytea, bytea' END;

      IF op_elem ? 'export' OR op_elem ? 'wasm_export' THEN
        op_cfg := jsonb_build_object(
          'module', name,
          'version', version,
          'export', op_export
        );
        IF op_elem ? 'return_length' THEN
          op_cfg := op_cfg || jsonb_build_object('return_length', (op_elem->>'return_length')::int4);
        END IF;
        IF op_elem ? 'return_mode' THEN
          op_cfg := op_cfg || jsonb_build_object('return_mode', op_elem->>'return_mode');
        END IF;
        IF op_elem ? 'arg_mode' THEN
          op_cfg := op_cfg || jsonb_build_object('arg_mode', op_elem->>'arg_mode');
        END IF;
        gen_sql := gen_sql || pg_catalog.format(
          'CREATE OR REPLACE FUNCTION %I.%I(%s) RETURNS %s LANGUAGE "pl/v8-wasm" IMMUTABLE STRICT AS %L;' || E'\n' ||
          'SELECT pgtle.create_operator_func(%L, %L, %L::pg_catalog.regprocedure);' || E'\n',
          t_schema, op_fn_name, op_sig_args, op_returns, op_cfg::text,
          t_schema, t_name, pg_catalog.format('%I.%I(%s)', t_schema, op_fn_name, op_sig_args)
        );
      ELSE
        gen_sql := gen_sql || pg_catalog.format(
          'DO $_op_chk_$ BEGIN IF pg_catalog.to_regprocedure(%L) IS NOT NULL THEN PERFORM pgtle.create_operator_func(%L, %L, %L::pg_catalog.regprocedure); END IF; END $_op_chk_$;' || E'\n',
          pg_catalog.format('%I.%I(%s)', t_schema, op_fn_name, op_sig_args),
          t_schema, t_name, pg_catalog.format('%I.%I(%s)', t_schema, op_fn_name, op_sig_args)
        );
      END IF;

      op_sym := COALESCE(NULLIF(op_elem->>'operator', ''), NULLIF(op_elem->>'symbol', ''), NULLIF(op_elem->>'op', ''));
      IF op_sym IS NOT NULL THEN
        IF op_nargs = 1 THEN
          gen_sql := gen_sql || pg_catalog.format(
            'CREATE OPERATOR %s (RIGHTARG = %I.%I, PROCEDURE = %I.%I);' || E'\n',
            op_sym, t_schema, t_name, t_schema, op_fn_name
          );
        ELSE
          gen_sql := gen_sql || pg_catalog.format(
            'CREATE OPERATOR %s (LEFTARG = %I.%I, RIGHTARG = %I.%I, PROCEDURE = %I.%I);' || E'\n',
            op_sym, t_schema, t_name, t_schema, t_name, t_schema, op_fn_name
          );
        END IF;
      END IF;
    END LOOP;
  END IF;

  IF manifest IS NOT NULL AND manifest ? 'sql' AND jsonb_typeof(manifest->'sql') = 'string' THEN
    gen_sql := gen_sql || E'\n' || (manifest->>'sql') || E'\n';
  END IF;

  IF ext_sql IS NOT NULL AND pg_catalog.btrim(ext_sql) <> '' THEN
    gen_sql := gen_sql || E'\n' || ext_sql || E'\n';
  END IF;

  PERFORM pgtle.uninstall_extension_if_exists(name);
  RETURN pgtle.install_extension(name, version, description, gen_sql, requires);
END;
$_pgtle_wasm_ext_$
LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION pgtle.install_wasm_extension
(
  name text,
  version text,
  description text,
  wasm_bytecode bytea,
  manifest jsonb,
  ext_sql text,
  requires text[]
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION pgtle.install_wasm_extension
(
  name text,
  version text,
  description text,
  wasm_bytecode bytea,
  manifest jsonb,
  ext_sql text,
  requires text[]
) TO pgtle_admin;
