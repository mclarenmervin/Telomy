-- The only genotypes this product stores.
--
-- Four rows per user at most, today. That is not a starting point to grow
-- from — it is the design, and the reasons are worth writing down next to the
-- table rather than only in `app/analytics/data/variants.v1.yaml`, because
-- the table is what somebody reads when they are deciding whether it is safe
-- to add a column.
--
-- ── What may be here ────────────────────────────────────────────────────────
--
-- Only rsids on the allowlist in `variants.v1.yaml`. A 23andMe raw export has
-- around 600,000 rows and several of them answer questions nobody should
-- receive from a wellness app unprompted. APOE is the one the programme plan
-- names: two SNPs give a person their Alzheimer's risk genotype, and in a
-- clinical setting that disclosure comes with counselling, consent taken
-- beforehand, and somebody in the room.
--
-- The filter is applied in `genetics.import_raw`, between parsing and
-- returning, so nothing downstream can bypass it by arriving in a different
-- file format. The discarded rows are never written anywhere: not to a
-- staging table, not to a log line, not to a column behind a feature flag.
-- The import returns a COUNT of what it dropped and no identities, because
-- "we read 600,000 rows and kept 3" is useful to a person and which of the
-- other 599,997 were interesting is the thing being refused.
--
-- A check constraint here would be a second copy of the allowlist that could
-- disagree with the file, so there is none; `genetics.context_for_results`
-- instead re-checks the allowlist on the way OUT. That is deliberate defence
-- in depth: removing a variant from the catalog stops it being shown
-- immediately, without waiting for a migration to delete the rows.
--
-- ── Why there is no tool and no loader method that reads this alone ─────────
--
-- The plan's rule is that a variant may never ORIGINATE an insight — it
-- appears only as context beside a measured marker. A `get_variants` the
-- agent could call is a diagnosis generator with extra steps: it would hold
-- the genotypes and the guardrails would be the only thing between them and
-- the person. So the only path out of this table is
-- `genetics.context_for_results`, which attaches a genotype to a
-- `biomarker_results` row the user actually has and returns nothing
-- otherwise.
--
-- ── Why the user may delete but not insert ─────────────────────────────────
--
-- Insert is the server's, through the import, for the same reason
-- `biomarker_results` is: a genotype the client could write is a genotype
-- that never passed the allowlist.
--
-- Delete is the user's, and this is the one table in the system where that
-- is more than a convenience. A person who regrets uploading their genome
-- must be able to take it back without closing their account, and making
-- them delete the account to do it would be an answer nobody should have to
-- accept. Erasure of the person still cascades as well.

create table if not exists genetic_variants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  -- An rsid from the allowlist. Lower-cased by the importer so that `RS1801133`
  -- and `rs1801133` cannot both exist for one person.
  rsid text not null check (rsid ~ '^rs[0-9]+$'),

  -- The two-letter call, e.g. `CT`. Alphabetically ordered by the importer for
  -- a VCF, and taken as written for a 23andMe export.
  --
  -- Indels are why this is not `char(2)`: 23andMe writes `D` and `I` and
  -- occasionally a single-letter call on a hemizygous locus.
  genotype text not null check (genotype ~ '^[ACGTDI]{1,2}$'),

  -- Which import produced it, so a user who uploads a second file can be told
  -- which one a value came from, and so a bad import can be undone as a unit.
  upload_id uuid,

  -- The catalog version the allowlist was read from when this was stored. If
  -- the list is narrowed later, this says which rows predate the narrowing.
  variants_version text not null,

  created_at timestamptz not null default now(),

  -- One genotype per locus per person. A second import of the same locus is an
  -- update of the same row, never a second row: two genotypes for one position
  -- is a contradiction, and which one a query returned would depend on order.
  unique (user_id, rsid)
);

create index if not exists genetic_variants_user_idx
  on genetic_variants (user_id);

alter table genetic_variants enable row level security;

create policy "users read their own variants"
  on genetic_variants for select
  using (user_id = (select auth.uid()));

-- Deliberately no insert and no update policy. The importer holds the service
-- role, and a genotype the client could write is a genotype that never passed
-- the allowlist.

create policy "users delete their own variants"
  on genetic_variants for delete
  using (user_id = (select auth.uid()));

comment on table genetic_variants is
  'Allowlisted wellness genotypes only. Everything else in an imported file is '
  'discarded at parse time and never written. There is no agent tool and no '
  'loader method that reads this table alone: a variant appears only as '
  'context beside a measured marker.';
