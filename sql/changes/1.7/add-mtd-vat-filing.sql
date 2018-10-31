-- Create new menu options for VAT Filing via the UK's HMRC
-- Making Tax Digital for Business api.
-- Use an existing gap in the top-level menu item position
-- sequence between 'Fixed Assets' and 'System'.
INSERT INTO menu_node (id, label, parent, position) VALUES
    (254, 'VAT Filing (HMRC)', 0, 21),
    (255, 'Authorisation', 254, 1),
    (256, 'VAT Returns', 254, 2),
    (257, 'Liabilities', 254, 3),
    (258, 'Payments', 254, 4);

INSERT INTO menu_attribute (node_id, attribute, value, id) VALUES
    (254, 'menu', '1', 682),
    (255, 'module', 'mtd_vat.pl', '683'),
    (255, 'action', 'authorisation_status', '684'),
    (256, 'module', 'mtd_vat.pl', '685'),
    (256, 'action', 'filter_obligations', '686'),
    (257, 'module', 'mtd_vat.pl', '687'),
    (257, 'action', 'filter_liabilities', '688'),
    (258, 'module', 'mtd_vat.pl', '689'),
    (258, 'action', 'filter_payments', '690');


-- Create new table for authorisation tokens, stored per entity,
-- usually a user, but could be a 'robot' or other entity.
CREATE TABLE mtd_token (
    id SERIAL NOT NULL PRIMARY KEY,
    entity_id INTEGER NOT NULL REFERENCES entity(id),
    access_token TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    expiry TIMESTAMP WITH TIME ZONE NOT NULL
);

COMMENT ON TABLE mtd_token IS
$$Holds authorisation tokens for access to the UK HMRC Making Tax
Digital api. These are issued for a specific entity.$$;

