-- ==========================================
-- ICT371 QUESTION 2: University Fee Payments
-- ==========================================

-- Clean up existing tables to prevent errors if you run this multiple times
DROP TABLE IF EXISTS payment_audit, payments, daily_collections, students CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL DEFAULT 0,
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
  -- Reject unknown student
  SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
  
  -- Return full fee if no payments exist (COALESCE handles NULL)
  SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  
  RETURN v_due - v_paid;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  -- Reject NULL, zero, or negative amounts
  IF p_amount IS NULL OR p_amount <= 0 THEN 
    RAISE EXCEPTION 'Amount must be positive'; 
  END IF;
  
  v_balance := fn_fee_balance(p_student_id);
  
  -- Reject payments above outstanding balance
  IF p_amount > v_balance THEN 
    RAISE EXCEPTION 'Payment exceeds balance (%)', v_balance; 
  END IF;
  
  -- Insert valid payment (does NOT change fee_due)
  INSERT INTO payments(student_id, amount, paid_on) 
  VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
-- AFTER INSERT row trigger that writes automatically to payment_audit.
-- Note: pr_receive_payment does NOT insert this row itself.
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit(payment_id, student_id, amount) 
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_payments_audit 
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
-- Shows outstanding balance, excluding fully settled students.
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name, fn_fee_balance(s.student_id) AS outstanding
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
CREATE INDEX idx_payments_student_date ON payments(student_id, paid_on);

-- (For your report, you can run this to see the plan):
-- EXPLAIN SELECT * FROM payments WHERE student_id=1 AND paid_on BETWEEN '2025-01-01' AND '2025-01-31';

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE) LANGUAGE plpgsql AS $$
BEGIN
  -- ON CONFLICT replaces existing summary row when rerun
  INSERT INTO daily_collections(collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount),0) 
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, 
        total_amount = EXCLUDED.total_amount;
END $$;

-- SCHEDULE: Requires pg_cron extension (often disabled locally).
-- SELECT cron.schedule('fees-daily','0 1 * * *',$$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);


-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert 3 students with different balances
-- Cara (S003) intentionally has NO payments.
INSERT INTO students(student_number, full_name, fee_due) VALUES
 ('S001','Alice',5000),
 ('S002','Bob',3000),
 ('S003','Cara',4000);  

-- 2. Load 6 valid payments through the procedure
CALL pr_receive_payment(1, 1000, CURRENT_DATE);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 2000, CURRENT_DATE);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 2500, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1,    CURRENT_DATE); -- Bob's final 1 K

-- 3. Check the View (Only Alice and Bob should show, Cara has no payments but still owes)
SELECT * FROM v_fee_balances;

-- 4. Check the Trigger Audit log (Should show 6 rows)
SELECT * FROM payment_audit;

-- 5. Run the daily refresh and check results
CALL pr_refresh_collections(CURRENT_DATE);
SELECT * FROM daily_collections;