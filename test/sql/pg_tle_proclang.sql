/*
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

\pset pager off
CREATE EXTENSION pg_tle;

-- Create test roles
CREATE ROLE lang_admin;
GRANT pgtle_admin TO lang_admin;

CREATE ROLE regular_user;

GRANT CREATE, USAGE ON SCHEMA public TO lang_admin;
GRANT CREATE, USAGE ON SCHEMA public TO regular_user;

-- Create a mock trusted procedural language as superuser (no validator)
CREATE TRUSTED LANGUAGE mock_pl HANDLER plpgsql_call_handler;

-- Create a handler function written in mock_pl (trusted PL)
CREATE FUNCTION my_js_handler()
RETURNS language_handler
AS $$ /* language handler implementation */ $$
LANGUAGE mock_pl;

-- 1. regular_user cannot create procedural language
SET SESSION AUTHORIZATION regular_user;
SELECT CURRENT_USER;

CREATE TRUSTED LANGUAGE test_lang HANDLER my_js_handler;

-- 2. regular_user cannot drop language
DROP LANGUAGE mock_pl;

-- Switch to lang_admin (has pgtle_admin role)
SET SESSION AUTHORIZATION lang_admin;
SELECT CURRENT_USER;

-- 3. lang_admin cannot create UNTRUSTED language
CREATE LANGUAGE untrusted_lang HANDLER my_js_handler;

-- 4. lang_admin cannot use non-existent handler
CREATE TRUSTED LANGUAGE missing_handler_lang HANDLER non_existent_func;

-- 5. lang_admin cannot use handler written in C / internal
CREATE TRUSTED LANGUAGE c_handler_lang HANDLER plpgsql_call_handler;

-- 6. lang_admin CAN successfully create TRUSTED language with trusted handler!
CREATE TRUSTED LANGUAGE test_lang HANDLER my_js_handler;

-- Verify language was created
SELECT lanname, lanpltrusted, lanispl FROM pg_language WHERE lanname = 'test_lang';

-- 7. lang_admin cannot drop system languages
DROP LANGUAGE plpgsql;

-- 8. lang_admin CAN drop the trusted language they created
DROP LANGUAGE test_lang;

-- Verify language was dropped
SELECT lanname FROM pg_language WHERE lanname = 'test_lang';

-- 9. Packaging custom language inside a TLE extension
RESET SESSION AUTHORIZATION;

SELECT pgtle.install_extension(
    'my_custom_dsl_ext',
    '1.0',
    'Custom DSL extension using mock_pl handler',
    $_pgtle_$
        CREATE FUNCTION dsl_handler() RETURNS language_handler AS 'dummy' LANGUAGE mock_pl;
        CREATE TRUSTED LANGUAGE my_dsl HANDLER dsl_handler;
    $_pgtle_$
);

-- Install as lang_admin
SET SESSION AUTHORIZATION lang_admin;

CREATE EXTENSION my_custom_dsl_ext;

SELECT lanname, lanpltrusted FROM pg_language WHERE lanname = 'my_dsl';

-- Dropping extension cascades and removes the language
DROP EXTENSION my_custom_dsl_ext;

SELECT lanname FROM pg_language WHERE lanname = 'my_dsl';

-- Cleanup
RESET SESSION AUTHORIZATION;
SELECT pgtle.uninstall_extension('my_custom_dsl_ext');
DROP FUNCTION my_js_handler CASCADE;
DROP LANGUAGE mock_pl CASCADE;
REVOKE ALL ON SCHEMA public FROM lang_admin;
REVOKE ALL ON SCHEMA public FROM regular_user;
DROP ROLE lang_admin;
DROP ROLE regular_user;
DROP EXTENSION pg_tle;
