ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES ('0006_default_privileges');
