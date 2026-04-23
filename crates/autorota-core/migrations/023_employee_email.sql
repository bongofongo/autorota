-- Optional email address on employees. Pairs with `preferred_contact`,
-- which now accepts "email" as a value in addition to "imessage"/"whatsapp".
ALTER TABLE employees ADD COLUMN email TEXT DEFAULT NULL;
