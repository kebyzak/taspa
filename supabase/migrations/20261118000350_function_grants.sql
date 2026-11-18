-- A schema-level default revoke cannot override PostgreSQL's global PUBLIC
-- EXECUTE default. Restrict existing RPCs and require a grant on new functions.
alter default privileges revoke execute on functions from public, anon, authenticated;
revoke execute on all functions in schema api, private from public;
revoke execute on function api.catalog_claim(text,text) from anon, authenticated;
revoke execute on function api.catalog_finish(text,uuid,int,jsonb,jsonb) from anon, authenticated;
