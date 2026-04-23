-- Collapse whatsapp into a single phone column, plus a preferred_contact
-- discriminator ("imessage" | "whatsapp" | NULL). One phone per employee.
UPDATE employees
   SET phone = whatsapp
 WHERE (phone IS NULL OR phone = '')
   AND whatsapp IS NOT NULL
   AND whatsapp != '';

ALTER TABLE employees DROP COLUMN whatsapp;
ALTER TABLE employees ADD COLUMN preferred_contact TEXT DEFAULT NULL;
