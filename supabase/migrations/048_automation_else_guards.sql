-- ============================================================
-- 048_automation_else_guards.sql
--
-- Per-contact rate limit for a condition step's OTHER (`no`)
-- branch — the "else" message.
--
-- Scenario this exists for: a customer keeps replying with messages
-- that never match the IF/ELSE IF predicates, so every inbound reply
-- falls through to the `no` branch and the else message fires again,
-- and again, forever. Two knobs on `step_config.else_guard` throttle
-- it:
--
--   cooldown_minutes — minimum gap between else-branch runs for the
--                      same contact (0 / absent = no gap)
--   max_count        — lifetime cap of else-branch runs per contact
--                      (0 / absent = unlimited)
--
-- State is keyed by (automation_id, contact_id), NOT by step id:
-- PATCH /api/automations/:id rewrites every automation_steps row
-- (replaceSteps = delete-all + reinsert), so step ids change on
-- every save and a step-keyed counter would silently reset itself
-- each time the author edited anything. If an automation has several
-- condition steps they share one budget per contact — deliberate
-- simplicity; the guard answers "how many else messages has this
-- automation sent this person".
--
-- The atomic check-and-increment lives in a SQL function because a
-- read-modify-write in JS races exactly the way the execution_count
-- counter used to (see 007): two inbound messages from the same
-- contact a few ms apart could both read N and both send.
--
-- Idempotent — safe to re-run.
-- ============================================================

CREATE TABLE IF NOT EXISTS automation_else_guards (
  automation_id UUID NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
  contact_id    UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  else_count    INTEGER NOT NULL DEFAULT 0,
  last_else_at  TIMESTAMPTZ,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (automation_id, contact_id)
);

CREATE OR REPLACE FUNCTION register_automation_else_guard(
  p_automation_id   UUID,
  p_contact_id      UUID,
  p_condition_step_id UUID,
  p_max_count       INTEGER,
  p_cooldown_minutes INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
  v_last  TIMESTAMPTZ;
BEGIN
  -- Nothing to guard: the else branch has no steps, so a "yes" here
  -- costs nothing and keeps the counter untouched.
  IF NOT EXISTS (
    SELECT 1 FROM automation_steps
    WHERE parent_step_id = p_condition_step_id AND branch = 'no'
  ) THEN
    RETURN TRUE;
  END IF;

  INSERT INTO automation_else_guards (automation_id, contact_id)
  VALUES (p_automation_id, p_contact_id)
  ON CONFLICT DO NOTHING;

  SELECT else_count, last_else_at
    INTO v_count, v_last
  FROM automation_else_guards
  WHERE automation_id = p_automation_id AND contact_id = p_contact_id
  FOR UPDATE;

  IF COALESCE(p_max_count, 0) > 0 AND v_count >= p_max_count THEN
    RETURN FALSE;
  END IF;

  IF COALESCE(p_cooldown_minutes, 0) > 0
     AND v_last IS NOT NULL
     AND v_last > NOW() - make_interval(mins => p_cooldown_minutes) THEN
    RETURN FALSE;
  END IF;

  UPDATE automation_else_guards
  SET else_count = v_count + 1,
      last_else_at = NOW(),
      updated_at = NOW()
  WHERE automation_id = p_automation_id AND contact_id = p_contact_id;

  RETURN TRUE;
END;
$$;

-- Only the service role needs to call this (engine uses the
-- service-role client). Lock anon / authenticated out so an
-- authenticated user can't reset someone else's else-message budget
-- via RPC.
REVOKE ALL ON FUNCTION register_automation_else_guard(UUID, UUID, UUID, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION register_automation_else_guard(UUID, UUID, UUID, INTEGER, INTEGER) FROM anon;
REVOKE ALL ON FUNCTION register_automation_else_guard(UUID, UUID, UUID, INTEGER, INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION register_automation_else_guard(UUID, UUID, UUID, INTEGER, INTEGER) TO service_role;
