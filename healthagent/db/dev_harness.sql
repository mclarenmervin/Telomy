-- LOCAL DEV ONLY. Lets the browser test page (publishable key, no login) act as
-- one fixed fake user. Run this to enable the test page; run the DROP block
-- at the bottom when you are finished.
create policy "dev harness events" on events
  for all to anon
  using (user_id = '00000000-0000-0000-0000-000000000001')
  with check (user_id = '00000000-0000-0000-0000-000000000001');

create policy "dev harness predictions read" on predictions
  for select to anon
  using (user_id = '00000000-0000-0000-0000-000000000001');

-- Cleanup (run when done):
-- drop policy "dev harness events" on events;
-- drop policy "dev harness predictions read" on predictions;
-- drop policy "temp harness read" on debug_log;
