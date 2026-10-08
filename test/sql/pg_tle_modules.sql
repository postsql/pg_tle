/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

\pset pager off
CREATE EXTENSION pg_tle;

-- 1. Check GUC
SHOW pgtle.module_cache_mode;
SET pgtle.module_cache_mode = 'shared';
SHOW pgtle.module_cache_mode;
SET pgtle.module_cache_mode = 'spi';
SHOW pgtle.module_cache_mode;

-- 2. Setup test roles
CREATE ROLE mod_admin;
GRANT pgtle_admin TO mod_admin;

CREATE ROLE reg_user;

-- 3. Negative security tests: reg_user
SET SESSION AUTHORIZATION reg_user;

-- Direct table insert must fail
INSERT INTO pgtle.modules (module_name, version, source_code)
VALUES ('bad_mod', '1.0.0', 'console.log("bad");');

-- install_module must fail
SELECT pgtle.install_module('bad_mod', '1.0.0', 'console.log("bad");');

-- uninstall_module must fail
SELECT pgtle.uninstall_module('bad_mod');

-- Reading via available_modules is permitted
SELECT * FROM pgtle.available_modules();

-- 4. Positive tests under mod_admin (SPI mode)
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION mod_admin;
SET pgtle.module_cache_mode = 'spi';

SELECT pgtle.install_module(
  'math_utils',
  '1.0.0',
  'export function add(a, b) { return a + b; }',
  '\x01020304'::bytea,
  ARRAY['core'],
  true
);

SELECT pgtle.install_module(
  'math_utils',
  '1.1.0',
  'export function add(a, b) { return a + b; } export function sub(a, b) { return a - b; }',
  '\x01020305'::bytea,
  ARRAY['core'],
  true
);

SELECT pgtle.install_module(
  'str_utils',
  '1.0.0',
  'export function trim(s) { return s.trim(); }',
  NULL,
  NULL,
  true
);

-- Check available modules
SELECT module_name, version, dependencies, is_trusted
FROM pgtle.available_modules()
ORDER BY module_name, version;

-- Get latest version of math_utils (should be 1.1.0)
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils');

-- Get specific version of math_utils (1.0.0)
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils', '1.0.0');

-- 5. Positive tests under mod_admin (Shared memory cache mode)
SET pgtle.module_cache_mode = 'shared';

-- First call: populates cache from SPI fallback
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils');

-- Second call: guaranteed shared memory cache hit
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils');

-- Version-specific lookup: first call populates cache
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils', '1.0.0');

-- Version-specific lookup: second call cache hit
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils', '1.0.0');

SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('str_utils');

-- Non-existent module
SELECT * FROM pgtle.get_module('non_existent');

-- 6. Module Update / Invalidation test
SELECT pgtle.install_module(
  'math_utils',
  '1.1.0',
  'export function add(a, b) { return a + b; } export function mul(a, b) { return a * b; }',
  '\x01020306'::bytea,
  ARRAY['core', 'math'],
  true
);

-- Verify updated content immediately visible in shared cache mode
SELECT module_name, version, source_code, bytecode, is_trusted
FROM pgtle.get_module('math_utils');

-- 7. Uninstall tests
-- Uninstall specific version 1.0.0 of math_utils
SELECT pgtle.uninstall_module('math_utils', '1.0.0');

-- Version 1.1.0 must still exist
SELECT module_name, version FROM pgtle.available_modules() ORDER BY module_name, version;

-- Verify 1.0.0 is gone from get_module
SELECT * FROM pgtle.get_module('math_utils', '1.0.0');

-- Uninstall all versions of math_utils
SELECT pgtle.uninstall_module('math_utils');

-- Only str_utils should remain
SELECT module_name, version FROM pgtle.available_modules() ORDER BY module_name, version;

-- Uninstall non-existent returns false
SELECT pgtle.uninstall_module('non_existent');

-- Cleanup modules
SELECT pgtle.uninstall_module('str_utils');
SELECT * FROM pgtle.available_modules();

-- 8. Cleanup roles and extension
RESET SESSION AUTHORIZATION;
DROP ROLE mod_admin;
DROP ROLE reg_user;
DROP EXTENSION pg_tle;
