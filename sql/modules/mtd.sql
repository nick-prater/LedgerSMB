set client_min_messages = 'warning';

-- SQL functions to support interation with the UK HMRC Making Tax Digital
-- (MTD) api.

-- Copyright (C) 2011 LedgerSMB Core Team.  Licensed under the GNU General
-- Public License v 2 or at your option any later version.

BEGIN;


CREATE OR REPLACE VIEW mtd__token_expiry_view AS
  SELECT mtd_token.*,
         (now() > mtd_token.expiry) AS has_expired,
         EXTRACT(HOURS FROM (expiry - now())) AS expiry_hours
  FROM mtd_token;

COMMENT ON VIEW mtd__token_expiry_view IS
$$Extended view of the mtd_token table, adding calculated fields
'has_expired' and 'expiry_hours' concerning the token expiry.$$;


CREATE OR REPLACE FUNCTION mtd__get_user_token()
RETURNS mtd__token_expiry_view AS $$

    SELECT * FROM mtd__token_expiry_view
    WHERE entity_id = person__get_my_entity_id()
    ORDER BY expiry DESC
    LIMIT 1;

$$ LANGUAGE SQL;

COMMENT ON FUNCTION mtd__get_user_token () IS
$$This returns the mtd_token record for the current user. If multiple records
are available, the record with the latest expiry time is returned.$$;


CREATE OR REPLACE FUNCTION mtd__get_token_by_id(in_id INTEGER)
RETURNS mtd__token_expiry_view AS $$

    SELECT * FROM mtd__token_expiry_view
    WHERE entity_id = person__get_my_entity_id()
    AND id = in_id;

$$ LANGUAGE SQL;

COMMENT ON FUNCTION mtd__get_token_by_id (INTEGER) IS
$$This returns the mtd_token record with the specified id, providing it belongs
to the current user. Tokens belonging to other users cannot be retrieved.$$;


CREATE OR REPLACE FUNCTION mtd__delete_user_token (in_mtd_token_id INTEGER)
RETURNS BOOL AS $$
BEGIN

    -- A user can only delete their own tokens
    DELETE FROM mtd_token
    WHERE entity_id = person__get_my_entity_id()
    AND id = in_mtd_token_id;

    RETURN FOUND;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mtd__delete_user_token (INTEGER) IS
$$This deletes the specified mtd_token record, which must belong to the
current user.$$;


CREATE OR REPLACE FUNCTION mtd__store_user_token (
    in_access_token TEXT,
    in_refresh_token TEXT,
    in_expiry TIMESTAMP WITH TIME ZONE
)
RETURNS INTEGER AS $$

    INSERT INTO mtd_token (entity_id, access_token, refresh_token, expiry)
    VALUES (
        person__get_my_entity_id(),
        in_access_token,
        in_refresh_token,
        in_expiry
    )
    RETURNING id;

$$ LANGUAGE SQL;

COMMENT ON FUNCTION mtd__store_user_token (TEXT, TEXT, TIMESTAMP WITH TIME ZONE) IS
$$Adds a mtd_token record for the current user. Returns the id of the inserted
mtd_token record.$$;


update defaults set value = 'yes' where setting_key = 'module_load_ok';

COMMIT;
