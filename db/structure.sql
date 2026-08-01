SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: folio_access_review_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_access_review_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_asset_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_asset_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_consolidation_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_consolidation_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_contract_allocations_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_contract_allocations_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_controlling_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_controlling_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_domain_events_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_domain_events_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION
    'domain_events is append-only: % on row id=% rejected',
    TG_OP, COALESCE(OLD.id, NEW.id)
    USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: folio_inventory_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_inventory_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_ledger_events_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_ledger_events_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION
    'ledger_events is append-only: % on row id=% rejected',
    TG_OP, COALESCE(OLD.id, NEW.id)
    USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: folio_procurement_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_procurement_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '% is immutable: % on row id=% rejected', TG_TABLE_NAME, TG_OP, OLD.id;
END;
$$;


--
-- Name: folio_protect_last_tenant_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_protect_last_tenant_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_was_owner boolean;
  new_is_same_tenant_owner boolean := false;
  another_owner_exists boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM role_templates
    WHERE id = OLD.role_template_id
      AND tenant_id = OLD.tenant_id
      AND code = 'owner'
  ) AND OLD.office_id IS NULL INTO old_was_owner;

  IF NOT old_was_owner THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    SELECT EXISTS (
      SELECT 1 FROM role_templates
      WHERE id = NEW.role_template_id
        AND tenant_id = OLD.tenant_id
        AND code = 'owner'
    ) AND NEW.office_id IS NULL AND NEW.tenant_id = OLD.tenant_id
    INTO new_is_same_tenant_owner;
  END IF;

  IF new_is_same_tenant_owner THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(OLD.tenant_id);
  SELECT EXISTS (
    SELECT 1
    FROM user_office_roles assignments
    INNER JOIN role_templates roles ON roles.id = assignments.role_template_id
    WHERE assignments.tenant_id = OLD.tenant_id
      AND assignments.office_id IS NULL
      AND assignments.id <> OLD.id
      AND roles.tenant_id = OLD.tenant_id
      AND roles.code = 'owner'
  ) INTO another_owner_exists;

  IF NOT another_owner_exists THEN
    RAISE EXCEPTION 'a tenant must retain at least one owner'
      USING ERRCODE = '23514', CONSTRAINT = 'tenant_requires_owner';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: access_review_attestations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.access_review_attestations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    access_review_run_id bigint NOT NULL,
    attested_by_id bigint NOT NULL,
    domain_event_id bigint NOT NULL,
    outcome character varying NOT NULL,
    notes text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT access_review_attestations_outcome_valid CHECK (((outcome)::text = ANY ((ARRAY['approved'::character varying, 'remediation_required'::character varying])::text[])))
);


--
-- Name: access_review_attestations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.access_review_attestations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: access_review_attestations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.access_review_attestations_id_seq OWNED BY public.access_review_attestations.id;


--
-- Name: access_review_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.access_review_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    domain_event_id bigint NOT NULL,
    snapshot jsonb NOT NULL,
    snapshot_sha256 character varying(64) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: access_review_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.access_review_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: access_review_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.access_review_runs_id_seq OWNED BY public.access_review_runs.id;


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    account_type character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active boolean DEFAULT true NOT NULL,
    monetary boolean DEFAULT false NOT NULL
);


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: allocation_cycles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allocation_cycles (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    sender_cost_center_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    allocation_type character varying DEFAULT 'distribution'::character varying NOT NULL,
    source_account_code character varying NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT allocation_cycles_range_valid CHECK (((valid_to IS NULL) OR (valid_to >= valid_from))),
    CONSTRAINT allocation_cycles_type_valid CHECK (((allocation_type)::text = 'distribution'::text))
);


--
-- Name: allocation_cycles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.allocation_cycles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: allocation_cycles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.allocation_cycles_id_seq OWNED BY public.allocation_cycles.id;


--
-- Name: allocation_receivers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allocation_receivers (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    allocation_cycle_id bigint NOT NULL,
    cost_center_id bigint NOT NULL,
    weight_basis_points integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT allocation_receivers_weight_valid CHECK (((weight_basis_points >= 1) AND (weight_basis_points <= 10000)))
);


--
-- Name: allocation_receivers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.allocation_receivers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: allocation_receivers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.allocation_receivers_id_seq OWNED BY public.allocation_receivers.id;


--
-- Name: allocation_run_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allocation_run_items (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    allocation_run_id bigint NOT NULL,
    sender_cost_center_id bigint NOT NULL,
    receiver_cost_center_id bigint NOT NULL,
    account_code character varying NOT NULL,
    weight_basis_points integer NOT NULL,
    amount_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT allocation_run_items_amount_positive CHECK ((amount_minor > 0))
);


--
-- Name: allocation_run_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.allocation_run_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: allocation_run_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.allocation_run_items_id_seq OWNED BY public.allocation_run_items.id;


--
-- Name: allocation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allocation_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    allocation_cycle_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    ledger_event_id bigint,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    mode character varying NOT NULL,
    status character varying NOT NULL,
    period_start date NOT NULL,
    through_date date NOT NULL,
    posting_date date NOT NULL,
    allocated_amount_minor bigint DEFAULT 0 NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT allocation_runs_amount_nonnegative CHECK ((allocated_amount_minor >= 0)),
    CONSTRAINT allocation_runs_dates_valid CHECK ((through_date >= period_start)),
    CONSTRAINT allocation_runs_mode_valid CHECK (((mode)::text = ANY ((ARRAY['simulate'::character varying, 'post'::character varying])::text[]))),
    CONSTRAINT allocation_runs_status_valid CHECK (((status)::text = ANY ((ARRAY['simulated'::character varying, 'posted'::character varying])::text[])))
);


--
-- Name: allocation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.allocation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: allocation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.allocation_runs_id_seq OWNED BY public.allocation_runs.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: asset_classes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_classes (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    apc_account_code character varying NOT NULL,
    accumulated_depreciation_account_code character varying NOT NULL,
    depreciation_expense_account_code character varying NOT NULL,
    gain_account_code character varying NOT NULL,
    loss_account_code character varying NOT NULL,
    default_useful_life_months integer NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT asset_classes_useful_life_positive CHECK ((default_useful_life_months > 0))
);


--
-- Name: asset_classes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_classes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_classes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_classes_id_seq OWNED BY public.asset_classes.id;


--
-- Name: asset_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_transactions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    fixed_asset_id bigint NOT NULL,
    asset_valuation_id bigint NOT NULL,
    depreciation_run_id bigint,
    created_by_id bigint NOT NULL,
    ledger_event_id bigint,
    idempotency_key character varying NOT NULL,
    transaction_type character varying NOT NULL,
    valuation_code character varying NOT NULL,
    asset_value_date date NOT NULL,
    posting_date date NOT NULL,
    amount_minor bigint NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT asset_transactions_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT asset_transactions_code_valid CHECK (((valuation_code)::text = ANY ((ARRAY['BOOK'::character varying, 'TAX_IT'::character varying])::text[]))),
    CONSTRAINT asset_transactions_type_valid CHECK (((transaction_type)::text = ANY ((ARRAY['acquisition'::character varying, 'depreciation'::character varying])::text[])))
);


--
-- Name: asset_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_transactions_id_seq OWNED BY public.asset_transactions.id;


--
-- Name: asset_valuation_terms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_valuation_terms (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    fixed_asset_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    valuation_code character varying NOT NULL,
    posts_to_ledger boolean DEFAULT false NOT NULL,
    depreciation_method character varying DEFAULT 'straight_line'::character varying NOT NULL,
    useful_life_months integer NOT NULL,
    residual_value_minor bigint DEFAULT 0 NOT NULL,
    depreciation_start_date date NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT asset_valuation_terms_code_valid CHECK (((valuation_code)::text = ANY ((ARRAY['BOOK'::character varying, 'TAX_IT'::character varying])::text[]))),
    CONSTRAINT asset_valuation_terms_life_positive CHECK ((useful_life_months > 0)),
    CONSTRAINT asset_valuation_terms_method_valid CHECK (((depreciation_method)::text = 'straight_line'::text)),
    CONSTRAINT asset_valuation_terms_range_valid CHECK (((valid_to IS NULL) OR (valid_to >= valid_from))),
    CONSTRAINT asset_valuation_terms_residual_nonnegative CHECK ((residual_value_minor >= 0))
);


--
-- Name: asset_valuation_terms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_valuation_terms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_valuation_terms_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_valuation_terms_id_seq OWNED BY public.asset_valuation_terms.id;


--
-- Name: asset_valuations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_valuations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    fixed_asset_id bigint NOT NULL,
    asset_valuation_term_id bigint NOT NULL,
    valuation_code character varying NOT NULL,
    posts_to_ledger boolean NOT NULL,
    gross_block_minor bigint DEFAULT 0 NOT NULL,
    accumulated_depreciation_minor bigint DEFAULT 0 NOT NULL,
    depreciation_posted_through date,
    lock_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT asset_valuations_code_valid CHECK (((valuation_code)::text = ANY ((ARRAY['BOOK'::character varying, 'TAX_IT'::character varying])::text[]))),
    CONSTRAINT asset_valuations_values_coherent CHECK (((gross_block_minor >= 0) AND (accumulated_depreciation_minor >= 0) AND (accumulated_depreciation_minor <= gross_block_minor)))
);


--
-- Name: asset_valuations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_valuations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_valuations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_valuations_id_seq OWNED BY public.asset_valuations.id;


--
-- Name: bank_statement_imports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_statement_imports (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    reconciled_domain_event_id bigint,
    bank_account_code character varying NOT NULL,
    currency character varying(3) NOT NULL,
    file_name character varying NOT NULL,
    source_sha256 character varying NOT NULL,
    statement_from date NOT NULL,
    statement_to date NOT NULL,
    opening_balance_minor bigint NOT NULL,
    closing_balance_minor bigint NOT NULL,
    row_count integer NOT NULL,
    status character varying DEFAULT 'imported'::character varying NOT NULL,
    reconciled_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT bank_statement_imports_period_valid CHECK ((statement_to >= statement_from)),
    CONSTRAINT bank_statement_imports_reconciliation_coherent CHECK (((((status)::text = 'imported'::text) AND (reconciled_domain_event_id IS NULL) AND (reconciled_at IS NULL)) OR (((status)::text = 'reconciled'::text) AND (reconciled_domain_event_id IS NOT NULL) AND (reconciled_at IS NOT NULL)))),
    CONSTRAINT bank_statement_imports_row_count_positive CHECK ((row_count > 0)),
    CONSTRAINT bank_statement_imports_status_valid CHECK (((status)::text = ANY ((ARRAY['imported'::character varying, 'reconciled'::character varying])::text[])))
);


--
-- Name: bank_statement_imports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bank_statement_imports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bank_statement_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bank_statement_imports_id_seq OWNED BY public.bank_statement_imports.id;


--
-- Name: bank_statement_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bank_statement_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    bank_statement_import_id bigint NOT NULL,
    line_no integer NOT NULL,
    booking_date date NOT NULL,
    value_date date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) NOT NULL,
    bank_reference character varying,
    description character varying NOT NULL,
    counterparty character varying,
    status character varying DEFAULT 'unmatched'::character varying NOT NULL,
    match_method character varying,
    matched_ledger_event_id bigint,
    matched_entry_line_no integer,
    matched_by_id bigint,
    matched_at timestamp(6) without time zone,
    ignore_reason character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT bank_statement_lines_amount_nonzero CHECK ((amount_minor <> 0)),
    CONSTRAINT bank_statement_lines_match_method_valid CHECK (((match_method IS NULL) OR ((match_method)::text = ANY ((ARRAY['exact'::character varying, 'manual'::character varying])::text[])))),
    CONSTRAINT bank_statement_lines_matched_line_positive CHECK (((matched_entry_line_no IS NULL) OR (matched_entry_line_no > 0))),
    CONSTRAINT bank_statement_lines_number_positive CHECK ((line_no > 0)),
    CONSTRAINT bank_statement_lines_resolution_coherent CHECK (((((status)::text = 'unmatched'::text) AND (match_method IS NULL) AND (matched_ledger_event_id IS NULL) AND (matched_entry_line_no IS NULL) AND (matched_by_id IS NULL) AND (matched_at IS NULL) AND (ignore_reason IS NULL)) OR (((status)::text = 'matched'::text) AND (match_method IS NOT NULL) AND (matched_ledger_event_id IS NOT NULL) AND (matched_entry_line_no IS NOT NULL) AND (matched_by_id IS NOT NULL) AND (matched_at IS NOT NULL) AND (ignore_reason IS NULL)) OR (((status)::text = 'ignored'::text) AND (match_method IS NULL) AND (matched_ledger_event_id IS NULL) AND (matched_entry_line_no IS NULL) AND (matched_by_id IS NULL) AND (matched_at IS NULL) AND (ignore_reason IS NOT NULL)))),
    CONSTRAINT bank_statement_lines_status_valid CHECK (((status)::text = ANY ((ARRAY['unmatched'::character varying, 'matched'::character varying, 'ignored'::character varying])::text[])))
);


--
-- Name: bank_statement_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bank_statement_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bank_statement_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bank_statement_lines_id_seq OWNED BY public.bank_statement_lines.id;


--
-- Name: consolidation_elimination_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consolidation_elimination_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    consolidation_group_id bigint NOT NULL,
    intercompany_transaction_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    ledger_event_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    posting_date date NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: consolidation_elimination_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consolidation_elimination_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consolidation_elimination_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consolidation_elimination_runs_id_seq OWNED BY public.consolidation_elimination_runs.id;


--
-- Name: consolidation_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consolidation_group_members (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    consolidation_group_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    ownership_basis_points integer DEFAULT 10000 NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT consolidation_members_dates_valid CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT consolidation_members_ownership_valid CHECK ((ownership_basis_points = 10000))
);


--
-- Name: consolidation_group_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consolidation_group_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consolidation_group_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consolidation_group_members_id_seq OWNED BY public.consolidation_group_members.id;


--
-- Name: consolidation_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.consolidation_groups (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    presentation_currency character varying(3) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: consolidation_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.consolidation_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: consolidation_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.consolidation_groups_id_seq OWNED BY public.consolidation_groups.id;


--
-- Name: contract_allocation_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_allocation_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_allocation_run_id bigint NOT NULL,
    contract_performance_obligation_id bigint NOT NULL,
    standalone_selling_price_minor bigint NOT NULL,
    allocation_ratio numeric(20,12) NOT NULL,
    allocated_price_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_allocation_lines_amounts_nonnegative CHECK (((standalone_selling_price_minor >= 0) AND (allocated_price_minor >= 0))),
    CONSTRAINT contract_allocation_lines_ratio_valid CHECK (((allocation_ratio >= (0)::numeric) AND (allocation_ratio <= (1)::numeric)))
);


--
-- Name: contract_allocation_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_allocation_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_allocation_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_allocation_lines_id_seq OWNED BY public.contract_allocation_lines.id;


--
-- Name: contract_allocation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_allocation_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    version integer NOT NULL,
    effective_date date NOT NULL,
    method character varying DEFAULT 'relative_ssp'::character varying NOT NULL,
    trigger character varying DEFAULT 'initial'::character varying NOT NULL,
    transaction_price_minor bigint NOT NULL,
    total_ssp_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_allocation_runs_amounts_valid CHECK (((transaction_price_minor >= 0) AND (total_ssp_minor > 0))),
    CONSTRAINT contract_allocation_runs_method_valid CHECK (((method)::text = 'relative_ssp'::text)),
    CONSTRAINT contract_allocation_runs_version_positive CHECK ((version > 0))
);


--
-- Name: contract_allocation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_allocation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_allocation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_allocation_runs_id_seq OWNED BY public.contract_allocation_runs.id;


--
-- Name: contract_milestones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_milestones (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    contract_performance_obligation_id bigint NOT NULL,
    milestone_no integer NOT NULL,
    description character varying NOT NULL,
    planned_date date NOT NULL,
    achieved_date date,
    recognition_amount_minor bigint NOT NULL,
    triggers_billing boolean DEFAULT false NOT NULL,
    triggers_recognition boolean DEFAULT true NOT NULL,
    acceptance_required boolean DEFAULT false NOT NULL,
    acceptance_date date,
    status character varying DEFAULT 'planned'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_milestones_amount_nonnegative CHECK ((recognition_amount_minor >= 0)),
    CONSTRAINT contract_milestones_number_positive CHECK ((milestone_no > 0)),
    CONSTRAINT contract_milestones_status_valid CHECK (((status)::text = ANY ((ARRAY['planned'::character varying, 'achieved'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: contract_milestones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_milestones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_milestones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_milestones_id_seq OWNED BY public.contract_milestones.id;


--
-- Name: contract_number_ranges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_number_ranges (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    fiscal_year integer NOT NULL,
    next_value integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_number_ranges_next_value_positive CHECK ((next_value > 0))
);


--
-- Name: contract_number_ranges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_number_ranges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_number_ranges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_number_ranges_id_seq OWNED BY public.contract_number_ranges.id;


--
-- Name: contract_performance_obligations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_performance_obligations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    obligation_no integer NOT NULL,
    description character varying NOT NULL,
    "distinct" boolean DEFAULT true NOT NULL,
    series boolean DEFAULT false NOT NULL,
    material_right boolean DEFAULT false NOT NULL,
    satisfaction character varying NOT NULL,
    over_time_criterion character varying,
    progress_measure character varying,
    standalone_selling_price_minor bigint NOT NULL,
    ssp_method character varying NOT NULL,
    service_start_date date,
    service_end_date date,
    revenue_account_code character varying DEFAULT '4000'::character varying NOT NULL,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_obligations_number_positive CHECK ((obligation_no > 0)),
    CONSTRAINT contract_obligations_satisfaction_valid CHECK (((satisfaction)::text = ANY ((ARRAY['point_in_time'::character varying, 'over_time'::character varying])::text[]))),
    CONSTRAINT contract_obligations_ssp_nonnegative CHECK ((standalone_selling_price_minor >= 0))
);


--
-- Name: contract_performance_obligations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_performance_obligations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_performance_obligations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_performance_obligations_id_seq OWNED BY public.contract_performance_obligations.id;


--
-- Name: contract_posting_run_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_posting_run_items (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_posting_run_id bigint NOT NULL,
    contract_schedule_line_id bigint NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    ledger_event_id bigint,
    error_message character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_posting_run_items_status_valid CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'simulated'::character varying, 'posted'::character varying, 'skipped'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: contract_posting_run_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_posting_run_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_posting_run_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_posting_run_items_id_seq OWNED BY public.contract_posting_run_items.id;


--
-- Name: contract_posting_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_posting_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    run_type character varying DEFAULT 'revenue_recognition'::character varying NOT NULL,
    mode character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    posting_date date NOT NULL,
    started_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_message character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_posting_runs_mode_valid CHECK (((mode)::text = ANY ((ARRAY['simulate'::character varying, 'post'::character varying])::text[]))),
    CONSTRAINT contract_posting_runs_status_valid CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'running'::character varying, 'simulated'::character varying, 'posted'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT contract_posting_runs_type_valid CHECK (((run_type)::text = 'revenue_recognition'::text))
);


--
-- Name: contract_posting_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_posting_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_posting_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_posting_runs_id_seq OWNED BY public.contract_posting_runs.id;


--
-- Name: contract_schedule_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_schedule_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    contract_schedule_id bigint NOT NULL,
    contract_milestone_id bigint,
    sequence integer NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    due_date date NOT NULL,
    original_effective_date date NOT NULL,
    amount_minor bigint NOT NULL,
    revenue_account_code character varying NOT NULL,
    status character varying DEFAULT 'planned'::character varying NOT NULL,
    posted_ledger_event_id bigint,
    posted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_schedule_lines_amount_nonnegative CHECK ((amount_minor >= 0)),
    CONSTRAINT contract_schedule_lines_period_valid CHECK ((period_end >= period_start)),
    CONSTRAINT contract_schedule_lines_sequence_positive CHECK ((sequence > 0)),
    CONSTRAINT contract_schedule_lines_status_valid CHECK (((status)::text = ANY ((ARRAY['planned'::character varying, 'posted'::character varying, 'superseded'::character varying])::text[])))
);


--
-- Name: contract_schedule_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_schedule_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_schedule_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_schedule_lines_id_seq OWNED BY public.contract_schedule_lines.id;


--
-- Name: contract_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_schedules (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint NOT NULL,
    contract_id bigint NOT NULL,
    contract_performance_obligation_id bigint NOT NULL,
    contract_allocation_line_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    version integer NOT NULL,
    kind character varying DEFAULT 'revenue'::character varying NOT NULL,
    method character varying NOT NULL,
    accounting_principle character varying DEFAULT 'ind_as'::character varying NOT NULL,
    currency character varying NOT NULL,
    status character varying DEFAULT 'current'::character varying NOT NULL,
    generated_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contract_schedules_kind_valid CHECK (((kind)::text = 'revenue'::text)),
    CONSTRAINT contract_schedules_method_valid CHECK (((method)::text = ANY ((ARRAY['straight_line'::character varying, 'milestone'::character varying])::text[]))),
    CONSTRAINT contract_schedules_status_valid CHECK (((status)::text = ANY ((ARRAY['current'::character varying, 'superseded'::character varying])::text[]))),
    CONSTRAINT contract_schedules_version_positive CHECK ((version > 0))
);


--
-- Name: contract_schedules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contract_schedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contract_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contract_schedules_id_seq OWNED BY public.contract_schedules.id;


--
-- Name: contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contracts (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    party_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    contract_number character varying NOT NULL,
    fiscal_year integer NOT NULL,
    title character varying NOT NULL,
    side character varying DEFAULT 'sell'::character varying NOT NULL,
    contract_type character varying DEFAULT 'service_agreement'::character varying NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    approval_date date,
    inception_date date,
    effective_date date,
    end_date date,
    enforceable_period_end date,
    closed_on date,
    term_type character varying DEFAULT 'fixed'::character varying NOT NULL,
    auto_renew boolean DEFAULT false NOT NULL,
    renewal_notice_days integer,
    notice_deadline_date date,
    currency character varying NOT NULL,
    total_contract_value_minor bigint NOT NULL,
    accounting_treatment character varying DEFAULT 'revenue_115'::character varying NOT NULL,
    jurisdiction character varying DEFAULT 'IN'::character varying NOT NULL,
    instrument_type character varying,
    execution_date date,
    stamp_status character varying DEFAULT 'pending'::character varying NOT NULL,
    stamp_state_code character varying,
    stamp_amount_minor bigint,
    stamp_certificate_reference character varying,
    stamp_date date,
    signature_status character varying DEFAULT 'unsigned'::character varying NOT NULL,
    signed_at timestamp(6) without time zone,
    registration_required boolean DEFAULT false NOT NULL,
    registration_status character varying DEFAULT 'not_required'::character varying NOT NULL,
    registration_reference character varying,
    tds_section character varying,
    gst_treatment character varying DEFAULT 'domestic_b2b'::character varying NOT NULL,
    place_of_supply_state_code character varying,
    hsn_sac_code character varying,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contracts_accounting_treatment_valid CHECK (((accounting_treatment)::text = ANY ((ARRAY['none'::character varying, 'revenue_115'::character varying, 'prepaid'::character varying, 'commitment'::character varying])::text[]))),
    CONSTRAINT contracts_registration_status_valid CHECK (((registration_status)::text = ANY ((ARRAY['not_required'::character varying, 'pending'::character varying, 'registered'::character varying, 'overdue'::character varying])::text[]))),
    CONSTRAINT contracts_renewal_notice_nonnegative CHECK (((renewal_notice_days IS NULL) OR (renewal_notice_days >= 0))),
    CONSTRAINT contracts_side_valid CHECK (((side)::text = ANY ((ARRAY['sell'::character varying, 'buy'::character varying, 'mutual'::character varying, 'internal'::character varying])::text[]))),
    CONSTRAINT contracts_signature_status_valid CHECK (((signature_status)::text = ANY ((ARRAY['unsigned'::character varying, 'partially_signed'::character varying, 'signed'::character varying])::text[]))),
    CONSTRAINT contracts_stamp_amount_nonnegative CHECK (((stamp_amount_minor IS NULL) OR (stamp_amount_minor >= 0))),
    CONSTRAINT contracts_stamp_status_valid CHECK (((stamp_status)::text = ANY ((ARRAY['not_applicable'::character varying, 'pending'::character varying, 'stamped'::character varying, 'under_stamped'::character varying])::text[]))),
    CONSTRAINT contracts_status_valid CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'signed'::character varying, 'active'::character varying, 'closed'::character varying])::text[]))),
    CONSTRAINT contracts_term_type_valid CHECK (((term_type)::text = ANY ((ARRAY['fixed'::character varying, 'evergreen'::character varying, 'auto_renew'::character varying, 'perpetual'::character varying, 'at_will'::character varying])::text[]))),
    CONSTRAINT contracts_total_value_nonnegative CHECK ((total_contract_value_minor >= 0))
);


--
-- Name: contracts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contracts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contracts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contracts_id_seq OWNED BY public.contracts.id;


--
-- Name: controlling_plan_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.controlling_plan_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    cost_center_id bigint NOT NULL,
    account_code character varying NOT NULL,
    version character varying DEFAULT 'BUDGET'::character varying NOT NULL,
    fiscal_year integer NOT NULL,
    period_no integer NOT NULL,
    currency character varying NOT NULL,
    amount_minor bigint NOT NULL,
    created_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT controlling_plan_lines_period_valid CHECK (((period_no >= 1) AND (period_no <= 16)))
);


--
-- Name: controlling_plan_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.controlling_plan_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: controlling_plan_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.controlling_plan_lines_id_seq OWNED BY public.controlling_plan_lines.id;


--
-- Name: controlling_segments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.controlling_segments (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: controlling_segments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.controlling_segments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: controlling_segments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.controlling_segments_id_seq OWNED BY public.controlling_segments.id;


--
-- Name: cost_centers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cost_centers (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    profit_center_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT cost_centers_range_valid CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- Name: cost_centers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cost_centers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cost_centers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cost_centers_id_seq OWNED BY public.cost_centers.id;


--
-- Name: depreciation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.depreciation_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    mode character varying NOT NULL,
    status character varying NOT NULL,
    through_date date NOT NULL,
    posting_date date NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT depreciation_runs_mode_valid CHECK (((mode)::text = ANY ((ARRAY['simulate'::character varying, 'post'::character varying])::text[]))),
    CONSTRAINT depreciation_runs_status_valid CHECK (((status)::text = ANY ((ARRAY['simulated'::character varying, 'posted'::character varying])::text[])))
);


--
-- Name: depreciation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.depreciation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: depreciation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.depreciation_runs_id_seq OWNED BY public.depreciation_runs.id;


--
-- Name: dimensions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dimensions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    label character varying NOT NULL,
    value_type character varying NOT NULL,
    committed boolean DEFAULT false NOT NULL,
    required_rule jsonb,
    derivation_rule jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: dimensions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dimensions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dimensions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dimensions_id_seq OWNED BY public.dimensions.id;


--
-- Name: document_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_allocations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_id bigint NOT NULL,
    line_no integer NOT NULL,
    target_entry_line_id bigint NOT NULL,
    target_source_event_id bigint NOT NULL,
    target_line_no integer NOT NULL,
    amount_minor bigint NOT NULL,
    clearing_mode character varying DEFAULT 'partial'::character varying NOT NULL,
    target_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    target_clearing_event_id bigint,
    settlement_clearing_event_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    target_reset_event_id bigint,
    settlement_reset_event_id bigint,
    target_ledger_id bigint NOT NULL,
    CONSTRAINT chk_document_allocations_mode CHECK (((clearing_mode)::text = ANY ((ARRAY['partial'::character varying, 'residual'::character varying])::text[]))),
    CONSTRAINT chk_document_allocations_positive CHECK ((amount_minor > 0))
);


--
-- Name: document_allocations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_allocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_allocations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_allocations_id_seq OWNED BY public.document_allocations.id;


--
-- Name: document_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_id bigint NOT NULL,
    line_no integer NOT NULL,
    account_code character varying NOT NULL,
    amount_minor bigint NOT NULL,
    currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    minor_unit_exponent integer DEFAULT 2 NOT NULL,
    narration character varying,
    extra jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    item_id bigint,
    quantity numeric(20,6),
    unit_price_minor bigint,
    taxable_minor bigint,
    hsn_sac_code character varying,
    tax_rate_basis_points integer,
    cess_rate_basis_points integer,
    tax_components jsonb,
    item_snapshot jsonb,
    credited_document_line_id bigint,
    debited_document_line_id bigint,
    purchase_order_line_id bigint,
    CONSTRAINT chk_document_lines_cess_rate CHECK (((cess_rate_basis_points IS NULL) OR ((cess_rate_basis_points >= 0) AND (cess_rate_basis_points <= 10000)))),
    CONSTRAINT chk_document_lines_invoice_amounts CHECK (((item_id IS NULL) OR ((quantity > (0)::numeric) AND (unit_price_minor >= 0) AND (taxable_minor > 0)))),
    CONSTRAINT chk_document_lines_tax_rate CHECK (((tax_rate_basis_points IS NULL) OR ((tax_rate_basis_points >= 0) AND (tax_rate_basis_points <= 4000))))
);


--
-- Name: document_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_lines_id_seq OWNED BY public.document_lines.id;


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    label character varying NOT NULL,
    posting_rule character varying NOT NULL,
    number_prefix character varying,
    version integer DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: document_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.document_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.document_types_id_seq OWNED BY public.document_types.id;


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    doc_type character varying NOT NULL,
    fiscal_year integer NOT NULL,
    document_number character varying,
    external_reference character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    state character varying DEFAULT 'draft'::character varying NOT NULL,
    narration character varying,
    posted_entry_id bigint,
    reverses_document_id bigint,
    reversed_by_document_id bigint,
    document_type_id bigint,
    document_date date,
    posting_date date,
    party_id bigint,
    tax_registration_id bigint,
    supply_type character varying,
    place_of_supply_state_code character varying,
    due_date date,
    currency character varying(3),
    minor_unit_exponent integer,
    subtotal_minor bigint,
    tax_minor bigint,
    total_minor bigint,
    party_snapshot jsonb,
    tax_registration_snapshot jsonb,
    tax_breakdown jsonb,
    credit_note_for_document_id bigint,
    reason_code character varying,
    debit_note_for_document_id bigint,
    tds_section character varying,
    tds_statutory_reference character varying,
    tds_base_basis character varying,
    tds_trigger_event character varying,
    tds_rate_basis_points integer DEFAULT 0 NOT NULL,
    tds_taxable_minor bigint DEFAULT 0 NOT NULL,
    tds_prior_taxable_minor bigint DEFAULT 0 NOT NULL,
    tds_prior_deducted_base_minor bigint DEFAULT 0 NOT NULL,
    tds_deductible_base_minor bigint DEFAULT 0 NOT NULL,
    tds_minor bigint DEFAULT 0 NOT NULL,
    place_of_supply_evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    contract_id bigint,
    contract_snapshot jsonb,
    purchase_order_id bigint,
    CONSTRAINT chk_documents_adjustment_reason CHECK (((reason_code IS NULL) OR ((reason_code)::text = ANY ((ARRAY['value_reduction'::character varying, 'service_deficiency'::character varying, 'return'::character varying, 'other'::character varying, 'quantity_underbilling'::character varying])::text[])))),
    CONSTRAINT chk_documents_invoice_totals CHECK (((subtotal_minor IS NULL) OR ((subtotal_minor > 0) AND (tax_minor >= 0) AND (total_minor = (subtotal_minor + tax_minor))))),
    CONSTRAINT chk_documents_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'parked'::character varying, 'posted'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT chk_documents_supply_type CHECK (((supply_type IS NULL) OR ((supply_type)::text = ANY ((ARRAY['B2B'::character varying, 'B2C'::character varying])::text[])))),
    CONSTRAINT chk_documents_tds_amounts_nonneg CHECK (((tds_rate_basis_points >= 0) AND (tds_taxable_minor >= 0) AND (tds_prior_taxable_minor >= 0) AND (tds_prior_deducted_base_minor >= 0) AND (tds_deductible_base_minor >= 0) AND (tds_minor >= 0))),
    CONSTRAINT chk_documents_tds_snapshot_complete CHECK ((((tds_section IS NULL) AND (tds_statutory_reference IS NULL) AND (tds_base_basis IS NULL) AND (tds_trigger_event IS NULL) AND (tds_rate_basis_points = 0) AND (tds_taxable_minor = 0) AND (tds_prior_taxable_minor = 0) AND (tds_prior_deducted_base_minor = 0) AND (tds_deductible_base_minor = 0) AND (tds_minor = 0)) OR ((tds_section IS NOT NULL) AND (tds_statutory_reference IS NOT NULL) AND (tds_base_basis IS NOT NULL) AND (tds_trigger_event IS NOT NULL) AND (tds_taxable_minor > 0) AND (tds_minor <= tds_deductible_base_minor))))
);


--
-- Name: documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documents_id_seq OWNED BY public.documents.id;


--
-- Name: domain_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.domain_events (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint,
    seq bigint NOT NULL,
    actor_user_id bigint,
    signature bytea,
    recorded_at timestamp(6) without time zone DEFAULT clock_timestamp() NOT NULL,
    prev_hash character varying(64) NOT NULL,
    hash_hex character varying(64) NOT NULL,
    hash_version integer DEFAULT 2 NOT NULL,
    ts character varying NOT NULL,
    actor character varying NOT NULL,
    action character varying NOT NULL,
    ref character varying,
    origin character varying NOT NULL,
    payload text NOT NULL,
    signing_key_id bigint,
    CONSTRAINT domain_events_seq_positive CHECK ((seq > 0))
);


--
-- Name: domain_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.domain_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: domain_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.domain_events_id_seq OWNED BY public.domain_events.id;


--
-- Name: einvoice_cancellations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.einvoice_cancellations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    einvoice_submission_id bigint NOT NULL,
    requested_by_id bigint NOT NULL,
    provider character varying NOT NULL,
    status character varying DEFAULT 'prepared'::character varying NOT NULL,
    request_id character varying NOT NULL,
    reason_code character varying(1) NOT NULL,
    remarks character varying(100) NOT NULL,
    requested_at timestamp(6) without time zone NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp(6) without time zone,
    cancelled_at timestamp(6) without time zone,
    provider_response jsonb,
    provider_response_sha256 character varying(64),
    error_code character varying,
    error_message text,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT einvoice_cancellations_attempt_count_nonnegative CHECK ((attempt_count >= 0)),
    CONSTRAINT einvoice_cancellations_evidence_complete CHECK ((((status)::text <> 'cancelled'::text) OR ((cancelled_at IS NOT NULL) AND (provider_response IS NOT NULL) AND (provider_response_sha256 IS NOT NULL)))),
    CONSTRAINT einvoice_cancellations_reason_valid CHECK (((reason_code)::text = ANY ((ARRAY['1'::character varying, '2'::character varying])::text[]))),
    CONSTRAINT einvoice_cancellations_status_valid CHECK (((status)::text = ANY ((ARRAY['prepared'::character varying, 'submitting'::character varying, 'cancelled'::character varying, 'rejected'::character varying, 'indeterminate'::character varying])::text[])))
);


--
-- Name: einvoice_cancellations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.einvoice_cancellations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: einvoice_cancellations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.einvoice_cancellations_id_seq OWNED BY public.einvoice_cancellations.id;


--
-- Name: einvoice_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.einvoice_submissions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_id bigint NOT NULL,
    tax_registration_id bigint NOT NULL,
    provider character varying DEFAULT 'offline_export'::character varying NOT NULL,
    status character varying DEFAULT 'prepared'::character varying NOT NULL,
    schema_version character varying DEFAULT '1.1'::character varying NOT NULL,
    request_id character varying NOT NULL,
    payload jsonb NOT NULL,
    payload_sha256 character varying(64) NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_attempt_at timestamp(6) without time zone,
    irn character varying(64),
    ack_number character varying,
    acknowledged_at timestamp(6) without time zone,
    signed_invoice text,
    signed_qr_code text,
    signature_status character varying DEFAULT 'not_checked'::character varying NOT NULL,
    provider_response jsonb,
    provider_response_sha256 character varying(64),
    error_code character varying,
    error_message text,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT einvoice_submissions_ack_evidence_complete CHECK ((((status)::text <> 'acknowledged'::text) OR ((irn IS NOT NULL) AND (ack_number IS NOT NULL) AND (acknowledged_at IS NOT NULL) AND (signed_invoice IS NOT NULL) AND (signed_qr_code IS NOT NULL) AND (provider_response IS NOT NULL) AND (provider_response_sha256 IS NOT NULL)))),
    CONSTRAINT einvoice_submissions_attempt_count_nonnegative CHECK ((attempt_count >= 0)),
    CONSTRAINT einvoice_submissions_signature_status_valid CHECK (((signature_status)::text = ANY ((ARRAY['not_checked'::character varying, 'provider_verified'::character varying, 'locally_verified'::character varying, 'failed'::character varying])::text[]))),
    CONSTRAINT einvoice_submissions_status_valid CHECK (((status)::text = ANY ((ARRAY['prepared'::character varying, 'submitting'::character varying, 'acknowledged'::character varying, 'rejected'::character varying, 'indeterminate'::character varying])::text[])))
);


--
-- Name: einvoice_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.einvoice_submissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: einvoice_submissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.einvoice_submissions_id_seq OWNED BY public.einvoice_submissions.id;


--
-- Name: entities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entities (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    legal_name character varying NOT NULL,
    functional_currency character varying(3) NOT NULL,
    fiscal_year_variant character varying NOT NULL,
    jurisdiction_profile character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: entities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.entities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: entities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.entities_id_seq OWNED BY public.entities.id;


--
-- Name: entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entries (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_id bigint,
    ledger_event_id bigint,
    document_date date NOT NULL,
    posting_date date NOT NULL,
    entered_at timestamp(6) without time zone NOT NULL,
    fiscal_year integer NOT NULL,
    period_no integer NOT NULL,
    reverses_id bigint,
    reversed_by_id bigint,
    reversal_reason_id bigint,
    alternative_posting_date date,
    role_template_id bigint,
    posting_limit_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_entries_period_no CHECK (((period_no >= 0) AND (period_no <= 16)))
);


--
-- Name: entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.entries_id_seq OWNED BY public.entries.id;


--
-- Name: entry_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entry_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entry_id bigint NOT NULL,
    line_no integer NOT NULL,
    account_code character varying NOT NULL,
    ledger_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    tax_registration_id bigint,
    cost_object_type character varying,
    cost_object_id bigint,
    profit_center_id bigint,
    segment_id bigint,
    functional_area_id bigint,
    line_class character varying DEFAULT 'real'::character varying NOT NULL,
    posting_layer character varying DEFAULT '00'::character varying NOT NULL,
    partner_entity_id bigint,
    partner_profit_center_id bigint,
    partner_segment_id bigint,
    partner_cost_object_type character varying,
    partner_cost_object_id bigint,
    intercompany_transaction_id character varying,
    party_id bigint,
    party_role character varying,
    item_id bigint,
    warehouse_id bigint,
    quantity numeric(20,6),
    uom character varying,
    movement_type character varying,
    open_item boolean DEFAULT false NOT NULL,
    item_class character varying,
    assignment character varying,
    baseline_date date,
    cleared_by_entry_id bigint,
    cleared_on date,
    reconciliation_gl_account_id bigint,
    due_date date,
    discount_pct numeric(7,4),
    discount_date date,
    value_date date,
    is_negative_posting boolean DEFAULT false NOT NULL,
    split_source_line_id bigint,
    split_kind character varying,
    liquidity_item_id bigint,
    cost_component_split jsonb,
    valuation_view character varying,
    extra jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    cleared_amount_minor bigint DEFAULT 0 NOT NULL,
    residual_of_line_id bigint,
    clearing_reason character varying,
    source_event_id bigint,
    hsn_sac_code character varying,
    tax_component character varying,
    tax_rate_basis_points integer,
    taxable_amount_minor bigint,
    fixed_asset_id bigint,
    asset_value_date date,
    CONSTRAINT chk_entry_lines_tax_component CHECK (((tax_component IS NULL) OR ((tax_component)::text = ANY ((ARRAY['cgst'::character varying, 'sgst'::character varying, 'utgst'::character varying, 'igst'::character varying, 'cess'::character varying])::text[]))))
);


--
-- Name: entry_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.entry_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: entry_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.entry_lines_id_seq OWNED BY public.entry_lines.id;


--
-- Name: exchange_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_rates (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    from_currency character varying(3) NOT NULL,
    to_currency character varying(3) NOT NULL,
    effective_on date NOT NULL,
    rate numeric(24,12) NOT NULL,
    rate_type character varying DEFAULT 'spot'::character varying NOT NULL,
    source character varying NOT NULL,
    created_by_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT exchange_rates_distinct_currencies CHECK (((from_currency)::text <> (to_currency)::text)),
    CONSTRAINT exchange_rates_positive CHECK ((rate > (0)::numeric)),
    CONSTRAINT exchange_rates_type_valid CHECK (((rate_type)::text = ANY ((ARRAY['spot'::character varying, 'closing'::character varying, 'average'::character varying])::text[])))
);


--
-- Name: exchange_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exchange_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exchange_rates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exchange_rates_id_seq OWNED BY public.exchange_rates.id;


--
-- Name: exchange_revaluation_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_revaluation_items (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    exchange_revaluation_run_id bigint NOT NULL,
    account_code character varying NOT NULL,
    foreign_currency character varying(3) NOT NULL,
    foreign_balance_minor bigint NOT NULL,
    carrying_functional_minor bigint NOT NULL,
    target_functional_minor bigint NOT NULL,
    difference_minor bigint NOT NULL,
    applied_rate numeric(24,12) NOT NULL,
    exchange_rate_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: exchange_revaluation_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exchange_revaluation_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exchange_revaluation_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exchange_revaluation_items_id_seq OWNED BY public.exchange_revaluation_items.id;


--
-- Name: exchange_revaluation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_revaluation_runs (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    revaluation_date date NOT NULL,
    mode character varying NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    ledger_event_id bigint,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    finished_at timestamp(6) without time zone,
    error_message character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT exchange_revaluation_runs_mode_valid CHECK (((mode)::text = ANY ((ARRAY['simulate'::character varying, 'post'::character varying])::text[]))),
    CONSTRAINT exchange_revaluation_runs_status_valid CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'simulated'::character varying, 'posted'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: exchange_revaluation_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.exchange_revaluation_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: exchange_revaluation_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.exchange_revaluation_runs_id_seq OWNED BY public.exchange_revaluation_runs.id;


--
-- Name: financial_statement_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_statement_assignments (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    financial_statement_version_id bigint NOT NULL,
    financial_statement_section_id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: financial_statement_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.financial_statement_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: financial_statement_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.financial_statement_assignments_id_seq OWNED BY public.financial_statement_assignments.id;


--
-- Name: financial_statement_sections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_statement_sections (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    financial_statement_version_id bigint NOT NULL,
    parent_id bigint,
    statement_type character varying NOT NULL,
    code character varying NOT NULL,
    label character varying NOT NULL,
    normal_balance character varying NOT NULL,
    sort_order integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_statement_sections_normal_balance CHECK (((normal_balance)::text = ANY ((ARRAY['debit'::character varying, 'credit'::character varying])::text[]))),
    CONSTRAINT chk_statement_sections_type CHECK (((statement_type)::text = ANY ((ARRAY['balance_sheet'::character varying, 'profit_and_loss'::character varying])::text[])))
);


--
-- Name: financial_statement_sections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.financial_statement_sections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: financial_statement_sections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.financial_statement_sections_id_seq OWNED BY public.financial_statement_sections.id;


--
-- Name: financial_statement_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_statement_versions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    name character varying NOT NULL,
    version integer NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_statement_versions_dates CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT chk_statement_versions_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: financial_statement_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.financial_statement_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: financial_statement_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.financial_statement_versions_id_seq OWNED BY public.financial_statement_versions.id;


--
-- Name: fixed_assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_assets (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    asset_class_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    created_domain_event_id bigint NOT NULL,
    asset_number character varying NOT NULL,
    component_number character varying DEFAULT '0000'::character varying NOT NULL,
    name character varying NOT NULL,
    description text,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    acquired_on date,
    capitalization_date date NOT NULL,
    quantity numeric(20,6) DEFAULT 1.0 NOT NULL,
    unit_of_measure character varying DEFAULT 'EA'::character varying NOT NULL,
    serial_number character varying,
    inventory_number character varying,
    manufacturer character varying,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT fixed_assets_quantity_positive CHECK ((quantity > (0)::numeric)),
    CONSTRAINT fixed_assets_status_valid CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'retired'::character varying])::text[])))
);


--
-- Name: fixed_assets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fixed_assets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fixed_assets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fixed_assets_id_seq OWNED BY public.fixed_assets.id;


--
-- Name: goods_receipt_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_receipt_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    goods_receipt_id bigint NOT NULL,
    purchase_order_line_id bigint NOT NULL,
    inventory_transaction_id bigint,
    received_quantity numeric(20,6) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT goods_receipt_lines_quantity_positive CHECK ((received_quantity > (0)::numeric))
);


--
-- Name: goods_receipt_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_receipt_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_receipt_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_receipt_lines_id_seq OWNED BY public.goods_receipt_lines.id;


--
-- Name: goods_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_receipts (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    purchase_order_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    receipt_number character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    received_on date NOT NULL,
    external_reference character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: goods_receipts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.goods_receipts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: goods_receipts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.goods_receipts_id_seq OWNED BY public.goods_receipts.id;


--
-- Name: intercompany_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercompany_transactions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    consolidation_group_id bigint NOT NULL,
    seller_entity_id bigint NOT NULL,
    buyer_entity_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    ledger_event_id bigint NOT NULL,
    transaction_code character varying NOT NULL,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    posting_date date NOT NULL,
    currency character varying(3) NOT NULL,
    amount_minor bigint NOT NULL,
    description character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT intercompany_transactions_amount_positive CHECK ((amount_minor > 0)),
    CONSTRAINT intercompany_transactions_distinct_entities CHECK ((seller_entity_id <> buyer_entity_id))
);


--
-- Name: intercompany_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.intercompany_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: intercompany_transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.intercompany_transactions_id_seq OWNED BY public.intercompany_transactions.id;


--
-- Name: inventory_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_movements (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    inventory_transaction_id bigint NOT NULL,
    item_id bigint NOT NULL,
    warehouse_id bigint NOT NULL,
    ledger_event_id bigint NOT NULL,
    entry_line_no integer NOT NULL,
    quantity numeric(20,6) NOT NULL,
    inventory_value_minor bigint NOT NULL,
    balance_quantity_after numeric(20,6) NOT NULL,
    balance_value_after_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT inventory_movements_balance_quantity_nonnegative CHECK ((balance_quantity_after >= (0)::numeric)),
    CONSTRAINT inventory_movements_balance_value_nonnegative CHECK ((balance_value_after_minor >= 0)),
    CONSTRAINT inventory_movements_quantity_nonzero CHECK ((quantity <> (0)::numeric)),
    CONSTRAINT inventory_movements_value_nonzero CHECK ((inventory_value_minor <> 0))
);


--
-- Name: inventory_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inventory_movements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inventory_movements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inventory_movements_id_seq OWNED BY public.inventory_movements.id;


--
-- Name: inventory_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_transactions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    item_id bigint NOT NULL,
    source_warehouse_id bigint,
    destination_warehouse_id bigint,
    ledger_event_id bigint NOT NULL,
    idempotency_key character varying NOT NULL,
    request_sha256 character varying NOT NULL,
    transaction_type character varying NOT NULL,
    posting_date date NOT NULL,
    quantity numeric(20,6) NOT NULL,
    unit_cost_minor bigint,
    total_value_minor bigint NOT NULL,
    offset_account_code character varying,
    external_reference character varying,
    reason character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT inventory_transactions_quantity_positive CHECK ((quantity > (0)::numeric)),
    CONSTRAINT inventory_transactions_type_valid CHECK (((transaction_type)::text = ANY ((ARRAY['receipt'::character varying, 'issue'::character varying, 'transfer'::character varying, 'adjustment_in'::character varying, 'adjustment_out'::character varying])::text[]))),
    CONSTRAINT inventory_transactions_value_positive CHECK ((total_value_minor > 0)),
    CONSTRAINT inventory_transactions_warehouse_coherent CHECK (((((transaction_type)::text = ANY ((ARRAY['issue'::character varying, 'adjustment_out'::character varying])::text[])) AND (source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NULL) AND (offset_account_code IS NOT NULL)) OR (((transaction_type)::text = ANY ((ARRAY['receipt'::character varying, 'adjustment_in'::character varying])::text[])) AND (source_warehouse_id IS NULL) AND (destination_warehouse_id IS NOT NULL) AND (offset_account_code IS NOT NULL) AND (unit_cost_minor IS NOT NULL)) OR (((transaction_type)::text = 'transfer'::text) AND (source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NOT NULL) AND (source_warehouse_id <> destination_warehouse_id) AND (offset_account_code IS NULL))))
);


--
-- Name: inventory_transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inventory_transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inventory_transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inventory_transactions_id_seq OWNED BY public.inventory_transactions.id;


--
-- Name: invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    email character varying NOT NULL,
    role_code character varying NOT NULL,
    invited_by_id bigint,
    accepted_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    delivery_state character varying DEFAULT 'not_sent'::character varying NOT NULL,
    delivery_attempted_at timestamp(6) without time zone
);


--
-- Name: invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invitations_id_seq OWNED BY public.invitations.id;


--
-- Name: items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.items (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    item_type character varying DEFAULT 'service'::character varying NOT NULL,
    description text,
    hsn_sac_code character varying NOT NULL,
    unit_of_measure character varying DEFAULT 'OTH'::character varying NOT NULL,
    tax_rate_basis_points integer DEFAULT 0 NOT NULL,
    cess_rate_basis_points integer DEFAULT 0 NOT NULL,
    income_account_code character varying NOT NULL,
    expense_account_code character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    inventory_class character varying,
    revision character varying,
    valuation_method character varying,
    inventory_account_code character varying,
    CONSTRAINT chk_items_cess_rate CHECK (((cess_rate_basis_points >= 0) AND (cess_rate_basis_points <= 10000))),
    CONSTRAINT chk_items_tax_rate CHECK (((tax_rate_basis_points >= 0) AND (tax_rate_basis_points <= 4000))),
    CONSTRAINT chk_items_type CHECK (((item_type)::text = ANY ((ARRAY['service'::character varying, 'good'::character varying])::text[]))),
    CONSTRAINT items_inventory_profile_coherent CHECK (((((item_type)::text = 'service'::text) AND (inventory_class IS NULL) AND (revision IS NULL) AND (valuation_method IS NULL) AND (inventory_account_code IS NULL)) OR (((item_type)::text = 'good'::text) AND ((inventory_class)::text = ANY ((ARRAY['raw_material'::character varying, 'wip'::character varying, 'finished_good'::character varying, 'trading'::character varying])::text[])) AND (revision IS NOT NULL) AND ((valuation_method)::text = 'moving_average'::text) AND (inventory_account_code IS NOT NULL))))
);


--
-- Name: items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.items_id_seq OWNED BY public.items.id;


--
-- Name: journal_entry_line_amounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entry_line_amounts (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entry_line_id bigint NOT NULL,
    slot_role character varying NOT NULL,
    currency character varying(3) NOT NULL,
    minor_unit_exponent smallint NOT NULL,
    amount_minor bigint NOT NULL,
    rate numeric(20,10),
    rate_date date,
    rate_source character varying,
    rate_basis character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: journal_entry_line_amounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.journal_entry_line_amounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: journal_entry_line_amounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.journal_entry_line_amounts_id_seq OWNED BY public.journal_entry_line_amounts.id;


--
-- Name: ledger_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_events (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint,
    seq bigint NOT NULL,
    actor_user_id bigint,
    signature bytea,
    recorded_at timestamp(6) without time zone DEFAULT clock_timestamp() NOT NULL,
    prev_hash character varying(64) NOT NULL,
    hash_hex character varying(64) NOT NULL,
    hash_version integer DEFAULT 2 NOT NULL,
    ts character varying NOT NULL,
    actor character varying NOT NULL,
    action character varying NOT NULL,
    ref character varying,
    origin character varying NOT NULL,
    payload text NOT NULL,
    schema_version integer DEFAULT 1 NOT NULL,
    signing_key_id bigint,
    CONSTRAINT ledger_events_seq_positive CHECK ((seq > 0))
);


--
-- Name: ledger_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ledger_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledger_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ledger_events_id_seq OWNED BY public.ledger_events.id;


--
-- Name: ledgers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledgers (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    kind character varying DEFAULT 'standard'::character varying NOT NULL,
    underlying_ledger_id bigint,
    posts_to_gl boolean DEFAULT true NOT NULL,
    valid_from date,
    valid_to date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ledgers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ledgers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledgers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ledgers_id_seq OWNED BY public.ledgers.id;


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: memberships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.memberships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: memberships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.memberships_id_seq OWNED BY public.memberships.id;


--
-- Name: number_ranges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.number_ranges (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    doc_type character varying NOT NULL,
    fiscal_year integer NOT NULL,
    next_value bigint DEFAULT 1 NOT NULL,
    prefix character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: number_ranges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.number_ranges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: number_ranges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.number_ranges_id_seq OWNED BY public.number_ranges.id;


--
-- Name: office_tax_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.office_tax_registrations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint NOT NULL,
    tax_registration_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: office_tax_registrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.office_tax_registrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: office_tax_registrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.office_tax_registrations_id_seq OWNED BY public.office_tax_registrations.id;


--
-- Name: offices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offices (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    default_place_of_supply character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    address_line1 character varying,
    address_line2 character varying,
    city character varying,
    postal_code character varying,
    state_code character varying,
    country_code character varying(2)
);


--
-- Name: offices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.offices_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: offices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.offices_id_seq OWNED BY public.offices.id;


--
-- Name: parties; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parties (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    party_number character varying NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active boolean DEFAULT true NOT NULL,
    email character varying,
    phone character varying,
    address_line1 character varying,
    address_line2 character varying,
    city character varying,
    postal_code character varying,
    state_code character varying,
    country_code character varying(2) DEFAULT 'IN'::character varying NOT NULL,
    default_tds_section character varying
);


--
-- Name: parties_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.parties_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: parties_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.parties_id_seq OWNED BY public.parties.id;


--
-- Name: party_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_roles (
    id bigint NOT NULL,
    party_id bigint NOT NULL,
    role character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: party_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.party_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: party_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.party_roles_id_seq OWNED BY public.party_roles.id;


--
-- Name: party_tax_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.party_tax_registrations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    party_id bigint NOT NULL,
    kind character varying DEFAULT 'GSTIN'::character varying NOT NULL,
    identifier character varying NOT NULL,
    state_code character varying,
    valid_from date NOT NULL,
    valid_to date,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_party_tax_registration_dates CHECK (((valid_to IS NULL) OR (valid_from IS NULL) OR (valid_to >= valid_from)))
);


--
-- Name: party_tax_registrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.party_tax_registrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: party_tax_registrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.party_tax_registrations_id_seq OWNED BY public.party_tax_registrations.id;


--
-- Name: period_controls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.period_controls (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    ledger_id bigint NOT NULL,
    account_class character varying DEFAULT 'ALL'::character varying NOT NULL,
    fiscal_year integer NOT NULL,
    period_no integer NOT NULL,
    state character varying DEFAULT 'open'::character varying NOT NULL,
    capability character varying,
    domain character varying DEFAULT 'posting'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_period_controls_period_no CHECK (((period_no >= 0) AND (period_no <= 16)))
);


--
-- Name: period_controls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.period_controls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: period_controls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.period_controls_id_seq OWNED BY public.period_controls.id;


--
-- Name: posting_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.posting_limits (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    name character varying NOT NULL,
    amount_minor bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: posting_limits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.posting_limits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: posting_limits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.posting_limits_id_seq OWNED BY public.posting_limits.id;


--
-- Name: procurement_matches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.procurement_matches (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_id bigint NOT NULL,
    document_line_id bigint NOT NULL,
    purchase_order_id bigint NOT NULL,
    purchase_order_line_id bigint NOT NULL,
    status character varying NOT NULL,
    billed_quantity numeric(20,6) NOT NULL,
    ordered_unit_price_minor bigint NOT NULL,
    billed_unit_price_minor bigint NOT NULL,
    exceptions jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT procurement_matches_quantity_positive CHECK ((billed_quantity > (0)::numeric)),
    CONSTRAINT procurement_matches_status_valid CHECK (((status)::text = ANY ((ARRAY['matched'::character varying, 'exception'::character varying])::text[])))
);


--
-- Name: procurement_matches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.procurement_matches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: procurement_matches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.procurement_matches_id_seq OWNED BY public.procurement_matches.id;


--
-- Name: profit_centers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profit_centers (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    controlling_segment_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT profit_centers_range_valid CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- Name: profit_centers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.profit_centers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profit_centers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.profit_centers_id_seq OWNED BY public.profit_centers.id;


--
-- Name: purchase_order_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_order_lines (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    purchase_order_id bigint NOT NULL,
    item_id bigint NOT NULL,
    warehouse_id bigint,
    line_no integer NOT NULL,
    description character varying NOT NULL,
    ordered_quantity numeric(20,6) NOT NULL,
    received_quantity numeric(20,6) DEFAULT 0.0 NOT NULL,
    unit_price_minor bigint NOT NULL,
    line_total_minor bigint NOT NULL,
    account_code character varying NOT NULL,
    item_type character varying NOT NULL,
    item_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT purchase_order_lines_item_type_valid CHECK (((item_type)::text = ANY ((ARRAY['service'::character varying, 'good'::character varying])::text[]))),
    CONSTRAINT purchase_order_lines_quantity_positive CHECK ((ordered_quantity > (0)::numeric)),
    CONSTRAINT purchase_order_lines_received_coherent CHECK (((received_quantity >= (0)::numeric) AND (received_quantity <= ordered_quantity))),
    CONSTRAINT purchase_order_lines_value_valid CHECK (((unit_price_minor >= 0) AND (line_total_minor > 0)))
);


--
-- Name: purchase_order_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_order_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: purchase_order_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.purchase_order_lines_id_seq OWNED BY public.purchase_order_lines.id;


--
-- Name: purchase_order_number_ranges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_order_number_ranges (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    fiscal_year integer NOT NULL,
    next_value integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT purchase_order_ranges_next_positive CHECK ((next_value > 0))
);


--
-- Name: purchase_order_number_ranges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_order_number_ranges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: purchase_order_number_ranges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.purchase_order_number_ranges_id_seq OWNED BY public.purchase_order_number_ranges.id;


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_orders (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    vendor_profile_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    approved_by_id bigint,
    order_number character varying NOT NULL,
    fiscal_year integer NOT NULL,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    order_date date NOT NULL,
    expected_on date,
    currency character varying NOT NULL,
    minor_unit_exponent integer NOT NULL,
    subtotal_minor bigint NOT NULL,
    description text,
    approved_at timestamp(6) without time zone,
    closed_on date,
    lock_version integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT purchase_orders_status_valid CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'approved'::character varying, 'partially_received'::character varying, 'received'::character varying, 'closed'::character varying])::text[]))),
    CONSTRAINT purchase_orders_subtotal_positive CHECK ((subtotal_minor > 0))
);


--
-- Name: purchase_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.purchase_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: purchase_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.purchase_orders_id_seq OWNED BY public.purchase_orders.id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    id bigint NOT NULL,
    role_template_id bigint NOT NULL,
    capability character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_permissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_permissions_id_seq OWNED BY public.role_permissions.id;


--
-- Name: role_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_templates (
    id bigint NOT NULL,
    tenant_id bigint,
    code character varying NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: role_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_templates_id_seq OWNED BY public.role_templates.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    last_seen_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: settlement_reallocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settlement_reallocations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    document_allocation_id bigint NOT NULL,
    target_entry_line_id bigint NOT NULL,
    target_source_event_id bigint NOT NULL,
    target_line_no integer NOT NULL,
    amount_minor bigint NOT NULL,
    clearing_mode character varying DEFAULT 'partial'::character varying NOT NULL,
    target_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    target_clearing_event_id bigint,
    settlement_clearing_event_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    target_ledger_id bigint NOT NULL,
    CONSTRAINT chk_settlement_reallocations_mode CHECK (((clearing_mode)::text = ANY ((ARRAY['partial'::character varying, 'residual'::character varying])::text[]))),
    CONSTRAINT chk_settlement_reallocations_positive CHECK ((amount_minor > 0))
);


--
-- Name: settlement_reallocations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.settlement_reallocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: settlement_reallocations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.settlement_reallocations_id_seq OWNED BY public.settlement_reallocations.id;


--
-- Name: sod_conflict_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sod_conflict_rules (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    severity character varying NOT NULL,
    capability_a character varying NOT NULL,
    capability_b character varying NOT NULL,
    description text NOT NULL,
    remediation text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT sod_conflict_rules_capabilities_distinct CHECK (((capability_a)::text <> (capability_b)::text)),
    CONSTRAINT sod_conflict_rules_severity_valid CHECK (((severity)::text = ANY ((ARRAY['critical'::character varying, 'high'::character varying, 'medium'::character varying, 'low'::character varying])::text[])))
);


--
-- Name: sod_conflict_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sod_conflict_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sod_conflict_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sod_conflict_rules_id_seq OWNED BY public.sod_conflict_rules.id;


--
-- Name: stock_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_balances (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    item_id bigint NOT NULL,
    warehouse_id bigint NOT NULL,
    quantity numeric(20,6) DEFAULT 0.0 NOT NULL,
    inventory_value_minor bigint DEFAULT 0 NOT NULL,
    lock_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT stock_balances_nonnegative_quantity CHECK ((quantity >= (0)::numeric)),
    CONSTRAINT stock_balances_nonnegative_value CHECK ((inventory_value_minor >= 0)),
    CONSTRAINT stock_balances_zero_position_coherent CHECK ((((quantity = (0)::numeric) AND (inventory_value_minor = 0)) OR (quantity > (0)::numeric)))
);


--
-- Name: stock_balances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stock_balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stock_balances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stock_balances_id_seq OWNED BY public.stock_balances.id;


--
-- Name: tax_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tax_registrations (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    kind character varying NOT NULL,
    identifier character varying NOT NULL,
    jurisdiction character varying,
    state_code character varying,
    valid_from date NOT NULL,
    valid_to date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_tax_registration_dates CHECK (((valid_to IS NULL) OR (valid_from IS NULL) OR (valid_to >= valid_from)))
);


--
-- Name: tax_registrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tax_registrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tax_registrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tax_registrations_id_seq OWNED BY public.tax_registrations.id;


--
-- Name: tds_deductions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tds_deductions (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    party_id bigint NOT NULL,
    section character varying NOT NULL,
    rate_basis_points integer NOT NULL,
    taxable_minor bigint NOT NULL,
    tds_minor bigint NOT NULL,
    deduction_date date NOT NULL,
    deductee_pan character varying,
    deductee_name_snapshot character varying NOT NULL,
    source_document_id bigint NOT NULL,
    entry_id bigint,
    fiscal_year integer NOT NULL,
    quarter integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    gross_minor bigint NOT NULL,
    gst_minor bigint NOT NULL,
    deductible_base_minor bigint NOT NULL,
    base_basis character varying NOT NULL,
    trigger_event character varying NOT NULL,
    statutory_reference character varying NOT NULL,
    kind character varying DEFAULT 'deduction'::character varying NOT NULL,
    reverses_tds_deduction_id bigint,
    CONSTRAINT tds_deductions_amounts_nonneg CHECK (((taxable_minor >= 0) AND (tds_minor >= 0))),
    CONSTRAINT tds_deductions_evidence_amounts_valid CHECK (((gross_minor >= 0) AND (gst_minor >= 0) AND (deductible_base_minor >= 0))),
    CONSTRAINT tds_deductions_kind_valid CHECK (((kind)::text = ANY ((ARRAY['deduction'::character varying, 'reversal'::character varying])::text[]))),
    CONSTRAINT tds_deductions_quarter_valid CHECK (((quarter >= 1) AND (quarter <= 4))),
    CONSTRAINT tds_deductions_reversal_link_valid CHECK (((((kind)::text = 'deduction'::text) AND (reverses_tds_deduction_id IS NULL)) OR (((kind)::text = 'reversal'::text) AND (reverses_tds_deduction_id IS NOT NULL))))
);


--
-- Name: tds_deductions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tds_deductions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tds_deductions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tds_deductions_id_seq OWNED BY public.tds_deductions.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id bigint NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    functional_currency character varying(3) DEFAULT 'INR'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    time_zone character varying DEFAULT 'UTC'::character varying NOT NULL
);


--
-- Name: tenants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenants_id_seq OWNED BY public.tenants.id;


--
-- Name: user_office_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_office_roles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint,
    role_template_id bigint NOT NULL,
    posting_limit_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: user_office_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_office_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_office_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_office_roles_id_seq OWNED BY public.user_office_roles.id;


--
-- Name: user_signing_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_signing_keys (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    key_version integer DEFAULT 1 NOT NULL,
    algorithm character varying DEFAULT 'ecdsa-p256-sha256'::character varying NOT NULL,
    public_key_pem text NOT NULL,
    encrypted_private_key text NOT NULL,
    fingerprint character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    retired_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT user_signing_keys_algorithm_valid CHECK (((algorithm)::text = 'ecdsa-p256-sha256'::text)),
    CONSTRAINT user_signing_keys_version_positive CHECK ((key_version > 0))
);


--
-- Name: user_signing_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_signing_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_signing_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_signing_keys_id_seq OWNED BY public.user_signing_keys.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    verified_at timestamp(6) without time zone,
    verification_delivery_state character varying DEFAULT 'not_sent'::character varying NOT NULL,
    verification_delivery_attempted_at timestamp(6) without time zone
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: vendor_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vendor_profiles (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    party_id bigint NOT NULL,
    created_by_id bigint NOT NULL,
    approved_by_id bigint,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    spend_authorized boolean DEFAULT false NOT NULL,
    purchasing_hold boolean DEFAULT false NOT NULL,
    posting_hold boolean DEFAULT false NOT NULL,
    payment_hold boolean DEFAULT false NOT NULL,
    payment_terms_days integer DEFAULT 30 NOT NULL,
    preferred_currency character varying NOT NULL,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT vendor_profiles_approval_coherent CHECK (((((status)::text = 'approved'::text) AND (spend_authorized = true) AND (approved_by_id IS NOT NULL) AND (approved_at IS NOT NULL)) OR (((status)::text <> 'approved'::text) AND (spend_authorized = false)))),
    CONSTRAINT vendor_profiles_status_valid CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'suspended'::character varying])::text[]))),
    CONSTRAINT vendor_profiles_terms_nonnegative CHECK ((payment_terms_days >= 0))
);


--
-- Name: vendor_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vendor_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vendor_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vendor_profiles_id_seq OWNED BY public.vendor_profiles.id;


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouses (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    office_id bigint NOT NULL,
    code character varying NOT NULL,
    name character varying NOT NULL,
    warehouse_type character varying DEFAULT 'general'::character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT warehouses_type_valid CHECK (((warehouse_type)::text = ANY ((ARRAY['general'::character varying, 'raw_material'::character varying, 'wip'::character varying, 'finished_goods'::character varying])::text[])))
);


--
-- Name: warehouses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.warehouses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: warehouses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.warehouses_id_seq OWNED BY public.warehouses.id;


--
-- Name: access_review_attestations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_attestations ALTER COLUMN id SET DEFAULT nextval('public.access_review_attestations_id_seq'::regclass);


--
-- Name: access_review_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_runs ALTER COLUMN id SET DEFAULT nextval('public.access_review_runs_id_seq'::regclass);


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: allocation_cycles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_cycles ALTER COLUMN id SET DEFAULT nextval('public.allocation_cycles_id_seq'::regclass);


--
-- Name: allocation_receivers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_receivers ALTER COLUMN id SET DEFAULT nextval('public.allocation_receivers_id_seq'::regclass);


--
-- Name: allocation_run_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_run_items ALTER COLUMN id SET DEFAULT nextval('public.allocation_run_items_id_seq'::regclass);


--
-- Name: allocation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_runs ALTER COLUMN id SET DEFAULT nextval('public.allocation_runs_id_seq'::regclass);


--
-- Name: asset_classes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_classes ALTER COLUMN id SET DEFAULT nextval('public.asset_classes_id_seq'::regclass);


--
-- Name: asset_transactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions ALTER COLUMN id SET DEFAULT nextval('public.asset_transactions_id_seq'::regclass);


--
-- Name: asset_valuation_terms id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuation_terms ALTER COLUMN id SET DEFAULT nextval('public.asset_valuation_terms_id_seq'::regclass);


--
-- Name: asset_valuations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuations ALTER COLUMN id SET DEFAULT nextval('public.asset_valuations_id_seq'::regclass);


--
-- Name: bank_statement_imports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_imports ALTER COLUMN id SET DEFAULT nextval('public.bank_statement_imports_id_seq'::regclass);


--
-- Name: bank_statement_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_lines ALTER COLUMN id SET DEFAULT nextval('public.bank_statement_lines_id_seq'::regclass);


--
-- Name: consolidation_elimination_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_elimination_runs ALTER COLUMN id SET DEFAULT nextval('public.consolidation_elimination_runs_id_seq'::regclass);


--
-- Name: consolidation_group_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_group_members ALTER COLUMN id SET DEFAULT nextval('public.consolidation_group_members_id_seq'::regclass);


--
-- Name: consolidation_groups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_groups ALTER COLUMN id SET DEFAULT nextval('public.consolidation_groups_id_seq'::regclass);


--
-- Name: contract_allocation_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_lines ALTER COLUMN id SET DEFAULT nextval('public.contract_allocation_lines_id_seq'::regclass);


--
-- Name: contract_allocation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_runs ALTER COLUMN id SET DEFAULT nextval('public.contract_allocation_runs_id_seq'::regclass);


--
-- Name: contract_milestones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_milestones ALTER COLUMN id SET DEFAULT nextval('public.contract_milestones_id_seq'::regclass);


--
-- Name: contract_number_ranges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_number_ranges ALTER COLUMN id SET DEFAULT nextval('public.contract_number_ranges_id_seq'::regclass);


--
-- Name: contract_performance_obligations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_performance_obligations ALTER COLUMN id SET DEFAULT nextval('public.contract_performance_obligations_id_seq'::regclass);


--
-- Name: contract_posting_run_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_run_items ALTER COLUMN id SET DEFAULT nextval('public.contract_posting_run_items_id_seq'::regclass);


--
-- Name: contract_posting_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_runs ALTER COLUMN id SET DEFAULT nextval('public.contract_posting_runs_id_seq'::regclass);


--
-- Name: contract_schedule_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedule_lines ALTER COLUMN id SET DEFAULT nextval('public.contract_schedule_lines_id_seq'::regclass);


--
-- Name: contract_schedules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules ALTER COLUMN id SET DEFAULT nextval('public.contract_schedules_id_seq'::regclass);


--
-- Name: contracts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts ALTER COLUMN id SET DEFAULT nextval('public.contracts_id_seq'::regclass);


--
-- Name: controlling_plan_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_plan_lines ALTER COLUMN id SET DEFAULT nextval('public.controlling_plan_lines_id_seq'::regclass);


--
-- Name: controlling_segments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_segments ALTER COLUMN id SET DEFAULT nextval('public.controlling_segments_id_seq'::regclass);


--
-- Name: cost_centers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers ALTER COLUMN id SET DEFAULT nextval('public.cost_centers_id_seq'::regclass);


--
-- Name: depreciation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.depreciation_runs ALTER COLUMN id SET DEFAULT nextval('public.depreciation_runs_id_seq'::regclass);


--
-- Name: dimensions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dimensions ALTER COLUMN id SET DEFAULT nextval('public.dimensions_id_seq'::regclass);


--
-- Name: document_allocations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_allocations ALTER COLUMN id SET DEFAULT nextval('public.document_allocations_id_seq'::regclass);


--
-- Name: document_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_lines ALTER COLUMN id SET DEFAULT nextval('public.document_lines_id_seq'::regclass);


--
-- Name: document_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types ALTER COLUMN id SET DEFAULT nextval('public.document_types_id_seq'::regclass);


--
-- Name: documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents ALTER COLUMN id SET DEFAULT nextval('public.documents_id_seq'::regclass);


--
-- Name: domain_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_events ALTER COLUMN id SET DEFAULT nextval('public.domain_events_id_seq'::regclass);


--
-- Name: einvoice_cancellations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations ALTER COLUMN id SET DEFAULT nextval('public.einvoice_cancellations_id_seq'::regclass);


--
-- Name: einvoice_submissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_submissions ALTER COLUMN id SET DEFAULT nextval('public.einvoice_submissions_id_seq'::regclass);


--
-- Name: entities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities ALTER COLUMN id SET DEFAULT nextval('public.entities_id_seq'::regclass);


--
-- Name: entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entries ALTER COLUMN id SET DEFAULT nextval('public.entries_id_seq'::regclass);


--
-- Name: entry_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entry_lines ALTER COLUMN id SET DEFAULT nextval('public.entry_lines_id_seq'::regclass);


--
-- Name: exchange_rates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rates ALTER COLUMN id SET DEFAULT nextval('public.exchange_rates_id_seq'::regclass);


--
-- Name: exchange_revaluation_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_items ALTER COLUMN id SET DEFAULT nextval('public.exchange_revaluation_items_id_seq'::regclass);


--
-- Name: exchange_revaluation_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_runs ALTER COLUMN id SET DEFAULT nextval('public.exchange_revaluation_runs_id_seq'::regclass);


--
-- Name: financial_statement_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments ALTER COLUMN id SET DEFAULT nextval('public.financial_statement_assignments_id_seq'::regclass);


--
-- Name: financial_statement_sections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections ALTER COLUMN id SET DEFAULT nextval('public.financial_statement_sections_id_seq'::regclass);


--
-- Name: financial_statement_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_versions ALTER COLUMN id SET DEFAULT nextval('public.financial_statement_versions_id_seq'::regclass);


--
-- Name: fixed_assets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets ALTER COLUMN id SET DEFAULT nextval('public.fixed_assets_id_seq'::regclass);


--
-- Name: goods_receipt_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_lines ALTER COLUMN id SET DEFAULT nextval('public.goods_receipt_lines_id_seq'::regclass);


--
-- Name: goods_receipts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts ALTER COLUMN id SET DEFAULT nextval('public.goods_receipts_id_seq'::regclass);


--
-- Name: intercompany_transactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions ALTER COLUMN id SET DEFAULT nextval('public.intercompany_transactions_id_seq'::regclass);


--
-- Name: inventory_movements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements ALTER COLUMN id SET DEFAULT nextval('public.inventory_movements_id_seq'::regclass);


--
-- Name: inventory_transactions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions ALTER COLUMN id SET DEFAULT nextval('public.inventory_transactions_id_seq'::regclass);


--
-- Name: invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations ALTER COLUMN id SET DEFAULT nextval('public.invitations_id_seq'::regclass);


--
-- Name: items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items ALTER COLUMN id SET DEFAULT nextval('public.items_id_seq'::regclass);


--
-- Name: journal_entry_line_amounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_line_amounts ALTER COLUMN id SET DEFAULT nextval('public.journal_entry_line_amounts_id_seq'::regclass);


--
-- Name: ledger_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_events ALTER COLUMN id SET DEFAULT nextval('public.ledger_events_id_seq'::regclass);


--
-- Name: ledgers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledgers ALTER COLUMN id SET DEFAULT nextval('public.ledgers_id_seq'::regclass);


--
-- Name: memberships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships ALTER COLUMN id SET DEFAULT nextval('public.memberships_id_seq'::regclass);


--
-- Name: number_ranges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.number_ranges ALTER COLUMN id SET DEFAULT nextval('public.number_ranges_id_seq'::regclass);


--
-- Name: office_tax_registrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.office_tax_registrations ALTER COLUMN id SET DEFAULT nextval('public.office_tax_registrations_id_seq'::regclass);


--
-- Name: offices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offices ALTER COLUMN id SET DEFAULT nextval('public.offices_id_seq'::regclass);


--
-- Name: parties id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties ALTER COLUMN id SET DEFAULT nextval('public.parties_id_seq'::regclass);


--
-- Name: party_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_roles ALTER COLUMN id SET DEFAULT nextval('public.party_roles_id_seq'::regclass);


--
-- Name: party_tax_registrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_tax_registrations ALTER COLUMN id SET DEFAULT nextval('public.party_tax_registrations_id_seq'::regclass);


--
-- Name: period_controls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.period_controls ALTER COLUMN id SET DEFAULT nextval('public.period_controls_id_seq'::regclass);


--
-- Name: posting_limits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting_limits ALTER COLUMN id SET DEFAULT nextval('public.posting_limits_id_seq'::regclass);


--
-- Name: procurement_matches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches ALTER COLUMN id SET DEFAULT nextval('public.procurement_matches_id_seq'::regclass);


--
-- Name: profit_centers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_centers ALTER COLUMN id SET DEFAULT nextval('public.profit_centers_id_seq'::regclass);


--
-- Name: purchase_order_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_lines ALTER COLUMN id SET DEFAULT nextval('public.purchase_order_lines_id_seq'::regclass);


--
-- Name: purchase_order_number_ranges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_number_ranges ALTER COLUMN id SET DEFAULT nextval('public.purchase_order_number_ranges_id_seq'::regclass);


--
-- Name: purchase_orders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders ALTER COLUMN id SET DEFAULT nextval('public.purchase_orders_id_seq'::regclass);


--
-- Name: role_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions ALTER COLUMN id SET DEFAULT nextval('public.role_permissions_id_seq'::regclass);


--
-- Name: role_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_templates ALTER COLUMN id SET DEFAULT nextval('public.role_templates_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: settlement_reallocations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_reallocations ALTER COLUMN id SET DEFAULT nextval('public.settlement_reallocations_id_seq'::regclass);


--
-- Name: sod_conflict_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sod_conflict_rules ALTER COLUMN id SET DEFAULT nextval('public.sod_conflict_rules_id_seq'::regclass);


--
-- Name: stock_balances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_balances ALTER COLUMN id SET DEFAULT nextval('public.stock_balances_id_seq'::regclass);


--
-- Name: tax_registrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations ALTER COLUMN id SET DEFAULT nextval('public.tax_registrations_id_seq'::regclass);


--
-- Name: tds_deductions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tds_deductions ALTER COLUMN id SET DEFAULT nextval('public.tds_deductions_id_seq'::regclass);


--
-- Name: tenants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants ALTER COLUMN id SET DEFAULT nextval('public.tenants_id_seq'::regclass);


--
-- Name: user_office_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles ALTER COLUMN id SET DEFAULT nextval('public.user_office_roles_id_seq'::regclass);


--
-- Name: user_signing_keys id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_signing_keys ALTER COLUMN id SET DEFAULT nextval('public.user_signing_keys_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: vendor_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_profiles ALTER COLUMN id SET DEFAULT nextval('public.vendor_profiles_id_seq'::regclass);


--
-- Name: warehouses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses ALTER COLUMN id SET DEFAULT nextval('public.warehouses_id_seq'::regclass);


--
-- Name: access_review_attestations access_review_attestations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_attestations
    ADD CONSTRAINT access_review_attestations_pkey PRIMARY KEY (id);


--
-- Name: access_review_runs access_review_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_runs
    ADD CONSTRAINT access_review_runs_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: allocation_cycles allocation_cycles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_cycles
    ADD CONSTRAINT allocation_cycles_pkey PRIMARY KEY (id);


--
-- Name: allocation_receivers allocation_receivers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_receivers
    ADD CONSTRAINT allocation_receivers_pkey PRIMARY KEY (id);


--
-- Name: allocation_run_items allocation_run_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_run_items
    ADD CONSTRAINT allocation_run_items_pkey PRIMARY KEY (id);


--
-- Name: allocation_runs allocation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_runs
    ADD CONSTRAINT allocation_runs_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: asset_classes asset_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_classes
    ADD CONSTRAINT asset_classes_pkey PRIMARY KEY (id);


--
-- Name: asset_transactions asset_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions
    ADD CONSTRAINT asset_transactions_pkey PRIMARY KEY (id);


--
-- Name: asset_valuation_terms asset_valuation_terms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuation_terms
    ADD CONSTRAINT asset_valuation_terms_pkey PRIMARY KEY (id);


--
-- Name: asset_valuations asset_valuations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuations
    ADD CONSTRAINT asset_valuations_pkey PRIMARY KEY (id);


--
-- Name: bank_statement_imports bank_statement_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_imports
    ADD CONSTRAINT bank_statement_imports_pkey PRIMARY KEY (id);


--
-- Name: bank_statement_lines bank_statement_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_lines
    ADD CONSTRAINT bank_statement_lines_pkey PRIMARY KEY (id);


--
-- Name: consolidation_elimination_runs consolidation_elimination_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_elimination_runs
    ADD CONSTRAINT consolidation_elimination_runs_pkey PRIMARY KEY (id);


--
-- Name: consolidation_group_members consolidation_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_group_members
    ADD CONSTRAINT consolidation_group_members_pkey PRIMARY KEY (id);


--
-- Name: consolidation_groups consolidation_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_groups
    ADD CONSTRAINT consolidation_groups_pkey PRIMARY KEY (id);


--
-- Name: contract_allocation_lines contract_allocation_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_lines
    ADD CONSTRAINT contract_allocation_lines_pkey PRIMARY KEY (id);


--
-- Name: contract_allocation_runs contract_allocation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_runs
    ADD CONSTRAINT contract_allocation_runs_pkey PRIMARY KEY (id);


--
-- Name: contract_milestones contract_milestones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_milestones
    ADD CONSTRAINT contract_milestones_pkey PRIMARY KEY (id);


--
-- Name: contract_number_ranges contract_number_ranges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_number_ranges
    ADD CONSTRAINT contract_number_ranges_pkey PRIMARY KEY (id);


--
-- Name: contract_performance_obligations contract_performance_obligations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_performance_obligations
    ADD CONSTRAINT contract_performance_obligations_pkey PRIMARY KEY (id);


--
-- Name: contract_posting_run_items contract_posting_run_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_run_items
    ADD CONSTRAINT contract_posting_run_items_pkey PRIMARY KEY (id);


--
-- Name: contract_posting_runs contract_posting_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_runs
    ADD CONSTRAINT contract_posting_runs_pkey PRIMARY KEY (id);


--
-- Name: contract_schedule_lines contract_schedule_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedule_lines
    ADD CONSTRAINT contract_schedule_lines_pkey PRIMARY KEY (id);


--
-- Name: contract_schedules contract_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules
    ADD CONSTRAINT contract_schedules_pkey PRIMARY KEY (id);


--
-- Name: contracts contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_pkey PRIMARY KEY (id);


--
-- Name: controlling_plan_lines controlling_plan_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_plan_lines
    ADD CONSTRAINT controlling_plan_lines_pkey PRIMARY KEY (id);


--
-- Name: controlling_segments controlling_segments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_segments
    ADD CONSTRAINT controlling_segments_pkey PRIMARY KEY (id);


--
-- Name: cost_centers cost_centers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_pkey PRIMARY KEY (id);


--
-- Name: depreciation_runs depreciation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.depreciation_runs
    ADD CONSTRAINT depreciation_runs_pkey PRIMARY KEY (id);


--
-- Name: dimensions dimensions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dimensions
    ADD CONSTRAINT dimensions_pkey PRIMARY KEY (id);


--
-- Name: document_allocations document_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_allocations
    ADD CONSTRAINT document_allocations_pkey PRIMARY KEY (id);


--
-- Name: document_lines document_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_lines
    ADD CONSTRAINT document_lines_pkey PRIMARY KEY (id);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: domain_events domain_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.domain_events
    ADD CONSTRAINT domain_events_pkey PRIMARY KEY (id);


--
-- Name: einvoice_cancellations einvoice_cancellations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations
    ADD CONSTRAINT einvoice_cancellations_pkey PRIMARY KEY (id);


--
-- Name: einvoice_submissions einvoice_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_submissions
    ADD CONSTRAINT einvoice_submissions_pkey PRIMARY KEY (id);


--
-- Name: entities entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_pkey PRIMARY KEY (id);


--
-- Name: entries entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entries
    ADD CONSTRAINT entries_pkey PRIMARY KEY (id);


--
-- Name: entry_lines entry_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entry_lines
    ADD CONSTRAINT entry_lines_pkey PRIMARY KEY (id);


--
-- Name: exchange_rates exchange_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT exchange_rates_pkey PRIMARY KEY (id);


--
-- Name: exchange_revaluation_items exchange_revaluation_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_items
    ADD CONSTRAINT exchange_revaluation_items_pkey PRIMARY KEY (id);


--
-- Name: exchange_revaluation_runs exchange_revaluation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_runs
    ADD CONSTRAINT exchange_revaluation_runs_pkey PRIMARY KEY (id);


--
-- Name: financial_statement_assignments financial_statement_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT financial_statement_assignments_pkey PRIMARY KEY (id);


--
-- Name: financial_statement_sections financial_statement_sections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections
    ADD CONSTRAINT financial_statement_sections_pkey PRIMARY KEY (id);


--
-- Name: financial_statement_versions financial_statement_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_versions
    ADD CONSTRAINT financial_statement_versions_pkey PRIMARY KEY (id);


--
-- Name: fixed_assets fixed_assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets
    ADD CONSTRAINT fixed_assets_pkey PRIMARY KEY (id);


--
-- Name: goods_receipt_lines goods_receipt_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT goods_receipt_lines_pkey PRIMARY KEY (id);


--
-- Name: goods_receipts goods_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_pkey PRIMARY KEY (id);


--
-- Name: intercompany_transactions intercompany_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions
    ADD CONSTRAINT intercompany_transactions_pkey PRIMARY KEY (id);


--
-- Name: inventory_movements inventory_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_pkey PRIMARY KEY (id);


--
-- Name: inventory_transactions inventory_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT inventory_transactions_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (id);


--
-- Name: journal_entry_line_amounts journal_entry_line_amounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_line_amounts
    ADD CONSTRAINT journal_entry_line_amounts_pkey PRIMARY KEY (id);


--
-- Name: ledger_events ledger_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_events
    ADD CONSTRAINT ledger_events_pkey PRIMARY KEY (id);


--
-- Name: ledgers ledgers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledgers
    ADD CONSTRAINT ledgers_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: number_ranges number_ranges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.number_ranges
    ADD CONSTRAINT number_ranges_pkey PRIMARY KEY (id);


--
-- Name: office_tax_registrations office_tax_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.office_tax_registrations
    ADD CONSTRAINT office_tax_registrations_pkey PRIMARY KEY (id);


--
-- Name: offices offices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offices
    ADD CONSTRAINT offices_pkey PRIMARY KEY (id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (id);


--
-- Name: party_roles party_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_roles
    ADD CONSTRAINT party_roles_pkey PRIMARY KEY (id);


--
-- Name: party_tax_registrations party_tax_registrations_no_active_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_tax_registrations
    ADD CONSTRAINT party_tax_registrations_no_active_overlap EXCLUDE USING gist (party_id WITH =, kind WITH =, daterange(valid_from, COALESCE(valid_to, 'infinity'::date), '[]'::text) WITH &&) WHERE (active);


--
-- Name: party_tax_registrations party_tax_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_tax_registrations
    ADD CONSTRAINT party_tax_registrations_pkey PRIMARY KEY (id);


--
-- Name: period_controls period_controls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.period_controls
    ADD CONSTRAINT period_controls_pkey PRIMARY KEY (id);


--
-- Name: posting_limits posting_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.posting_limits
    ADD CONSTRAINT posting_limits_pkey PRIMARY KEY (id);


--
-- Name: procurement_matches procurement_matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches
    ADD CONSTRAINT procurement_matches_pkey PRIMARY KEY (id);


--
-- Name: profit_centers profit_centers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_centers
    ADD CONSTRAINT profit_centers_pkey PRIMARY KEY (id);


--
-- Name: purchase_order_lines purchase_order_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_pkey PRIMARY KEY (id);


--
-- Name: purchase_order_number_ranges purchase_order_number_ranges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_number_ranges
    ADD CONSTRAINT purchase_order_number_ranges_pkey PRIMARY KEY (id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: role_templates role_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_templates
    ADD CONSTRAINT role_templates_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: settlement_reallocations settlement_reallocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_reallocations
    ADD CONSTRAINT settlement_reallocations_pkey PRIMARY KEY (id);


--
-- Name: sod_conflict_rules sod_conflict_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sod_conflict_rules
    ADD CONSTRAINT sod_conflict_rules_pkey PRIMARY KEY (id);


--
-- Name: stock_balances stock_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_balances
    ADD CONSTRAINT stock_balances_pkey PRIMARY KEY (id);


--
-- Name: tax_registrations tax_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations
    ADD CONSTRAINT tax_registrations_pkey PRIMARY KEY (id);


--
-- Name: tds_deductions tds_deductions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tds_deductions
    ADD CONSTRAINT tds_deductions_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: user_office_roles user_office_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT user_office_roles_pkey PRIMARY KEY (id);


--
-- Name: user_signing_keys user_signing_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_signing_keys
    ADD CONSTRAINT user_signing_keys_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: vendor_profiles vendor_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_profiles
    ADD CONSTRAINT vendor_profiles_pkey PRIMARY KEY (id);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: idx_document_allocations_stable_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_allocations_stable_target ON public.document_allocations USING btree (tenant_id, target_source_event_id, target_ledger_id, target_line_no);


--
-- Name: idx_documents_credit_note_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_credit_note_source ON public.documents USING btree (tenant_id, credit_note_for_document_id, state);


--
-- Name: idx_documents_debit_note_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_debit_note_source ON public.documents USING btree (tenant_id, debit_note_for_document_id, state);


--
-- Name: idx_documents_tenant_party_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_tenant_party_date ON public.documents USING btree (tenant_id, party_id, document_date);


--
-- Name: idx_documents_tenant_tax_registration_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_tenant_tax_registration_date ON public.documents USING btree (tenant_id, tax_registration_id, document_date);


--
-- Name: idx_documents_unique_vendor_bill_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_documents_unique_vendor_bill_reference ON public.documents USING btree (tenant_id, party_id, external_reference) WHERE (((doc_type)::text = 'PB'::text) AND (external_reference IS NOT NULL));


--
-- Name: idx_documents_unique_vendor_credit_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_documents_unique_vendor_credit_reference ON public.documents USING btree (tenant_id, party_id, external_reference) WHERE (((doc_type)::text = 'PC'::text) AND (external_reference IS NOT NULL));


--
-- Name: idx_documents_unique_vendor_debit_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_documents_unique_vendor_debit_reference ON public.documents USING btree (tenant_id, party_id, external_reference) WHERE (((doc_type)::text = 'PD'::text) AND (external_reference IS NOT NULL));


--
-- Name: idx_entry_lines_tax_reporting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_entry_lines_tax_reporting ON public.entry_lines USING btree (tenant_id, tax_registration_id, tax_component) WHERE (tax_component IS NOT NULL);


--
-- Name: idx_office_tax_registrations_tenant_registration; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_office_tax_registrations_tenant_registration ON public.office_tax_registrations USING btree (tenant_id, tax_registration_id);


--
-- Name: idx_office_tax_registrations_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_office_tax_registrations_unique ON public.office_tax_registrations USING btree (office_id, tax_registration_id);


--
-- Name: idx_on_intercompany_transaction_id_c60befa88e; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_intercompany_transaction_id_c60befa88e ON public.consolidation_elimination_runs USING btree (intercompany_transaction_id);


--
-- Name: idx_on_tenant_id_kind_identifier_valid_from_f473959005; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_tenant_id_kind_identifier_valid_from_f473959005 ON public.tax_registrations USING btree (tenant_id, kind, identifier, valid_from);


--
-- Name: idx_on_tenant_id_status_capitalization_date_d37ddd9c8f; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_tenant_id_status_capitalization_date_d37ddd9c8f ON public.fixed_assets USING btree (tenant_id, status, capitalization_date);


--
-- Name: idx_party_tax_registrations_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_party_tax_registrations_identity ON public.party_tax_registrations USING btree (tenant_id, kind, identifier, valid_from);


--
-- Name: idx_posting_limits_id_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_posting_limits_id_tenant ON public.posting_limits USING btree (id, tenant_id);


--
-- Name: idx_role_templates_id_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_role_templates_id_tenant ON public.role_templates USING btree (id, tenant_id);


--
-- Name: idx_settlement_reallocations_stable_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_settlement_reallocations_stable_target ON public.settlement_reallocations USING btree (tenant_id, target_source_event_id, target_ledger_id, target_line_no);


--
-- Name: idx_statement_assignments_section; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_assignments_section ON public.financial_statement_assignments USING btree (financial_statement_section_id);


--
-- Name: idx_statement_assignments_tenant_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_assignments_tenant_account ON public.financial_statement_assignments USING btree (tenant_id, account_id);


--
-- Name: idx_statement_assignments_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_assignments_version ON public.financial_statement_assignments USING btree (financial_statement_version_id);


--
-- Name: idx_statement_assignments_version_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_statement_assignments_version_account ON public.financial_statement_assignments USING btree (financial_statement_version_id, account_id);


--
-- Name: idx_statement_sections_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_sections_order ON public.financial_statement_sections USING btree (financial_statement_version_id, statement_type, sort_order);


--
-- Name: idx_statement_sections_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_sections_parent ON public.financial_statement_sections USING btree (parent_id);


--
-- Name: idx_statement_sections_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_sections_version ON public.financial_statement_sections USING btree (financial_statement_version_id);


--
-- Name: idx_statement_sections_version_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_statement_sections_version_code ON public.financial_statement_sections USING btree (financial_statement_version_id, code);


--
-- Name: idx_statement_versions_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_statement_versions_effective ON public.financial_statement_versions USING btree (tenant_id, effective_from);


--
-- Name: idx_statement_versions_tenant_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_statement_versions_tenant_version ON public.financial_statement_versions USING btree (tenant_id, version);


--
-- Name: index_access_review_attestations_on_access_review_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_access_review_attestations_on_access_review_run_id ON public.access_review_attestations USING btree (access_review_run_id);


--
-- Name: index_access_review_attestations_on_attested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_access_review_attestations_on_attested_by_id ON public.access_review_attestations USING btree (attested_by_id);


--
-- Name: index_access_review_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_access_review_runs_on_created_by_id ON public.access_review_runs USING btree (created_by_id);


--
-- Name: index_access_review_runs_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_access_review_runs_on_tenant_id ON public.access_review_runs USING btree (tenant_id);


--
-- Name: index_access_review_runs_on_tenant_id_and_snapshot_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_access_review_runs_on_tenant_id_and_snapshot_sha256 ON public.access_review_runs USING btree (tenant_id, snapshot_sha256);


--
-- Name: index_accounts_on_tenant_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_tenant_id_and_active ON public.accounts USING btree (tenant_id, active);


--
-- Name: index_accounts_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_tenant_id_and_code ON public.accounts USING btree (tenant_id, code);


--
-- Name: index_accounts_on_tenant_id_and_monetary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_tenant_id_and_monetary ON public.accounts USING btree (tenant_id, monetary) WHERE (monetary = true);


--
-- Name: index_allocation_cycles_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_cycles_on_entity_id ON public.allocation_cycles USING btree (entity_id);


--
-- Name: index_allocation_cycles_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_cycles_on_office_id ON public.allocation_cycles USING btree (office_id);


--
-- Name: index_allocation_cycles_on_sender_cost_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_cycles_on_sender_cost_center_id ON public.allocation_cycles USING btree (sender_cost_center_id);


--
-- Name: index_allocation_cycles_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_allocation_cycles_on_tenant_id_and_code ON public.allocation_cycles USING btree (tenant_id, code);


--
-- Name: index_allocation_receivers_on_allocation_cycle_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_receivers_on_allocation_cycle_id ON public.allocation_receivers USING btree (allocation_cycle_id);


--
-- Name: index_allocation_receivers_on_cost_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_receivers_on_cost_center_id ON public.allocation_receivers USING btree (cost_center_id);


--
-- Name: index_allocation_receivers_on_cycle_and_center; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_allocation_receivers_on_cycle_and_center ON public.allocation_receivers USING btree (allocation_cycle_id, cost_center_id);


--
-- Name: index_allocation_run_items_on_allocation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_run_items_on_allocation_run_id ON public.allocation_run_items USING btree (allocation_run_id);


--
-- Name: index_allocation_run_items_on_receiver; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_allocation_run_items_on_receiver ON public.allocation_run_items USING btree (allocation_run_id, receiver_cost_center_id);


--
-- Name: index_allocation_run_items_on_receiver_cost_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_run_items_on_receiver_cost_center_id ON public.allocation_run_items USING btree (receiver_cost_center_id);


--
-- Name: index_allocation_run_items_on_sender_cost_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_run_items_on_sender_cost_center_id ON public.allocation_run_items USING btree (sender_cost_center_id);


--
-- Name: index_allocation_runs_on_allocation_cycle_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_runs_on_allocation_cycle_id ON public.allocation_runs USING btree (allocation_cycle_id);


--
-- Name: index_allocation_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_allocation_runs_on_created_by_id ON public.allocation_runs USING btree (created_by_id);


--
-- Name: index_allocation_runs_on_tenant_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_allocation_runs_on_tenant_id_and_idempotency_key ON public.allocation_runs USING btree (tenant_id, idempotency_key);


--
-- Name: index_asset_classes_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_asset_classes_on_tenant_id_and_code ON public.asset_classes USING btree (tenant_id, code);


--
-- Name: index_asset_terms_on_effective_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_asset_terms_on_effective_identity ON public.asset_valuation_terms USING btree (tenant_id, fixed_asset_id, valuation_code, valid_from);


--
-- Name: index_asset_terms_on_one_current_term; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_asset_terms_on_one_current_term ON public.asset_valuation_terms USING btree (fixed_asset_id, valuation_code) WHERE (valid_to IS NULL);


--
-- Name: index_asset_transactions_on_asset_valuation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_transactions_on_asset_valuation_id ON public.asset_transactions USING btree (asset_valuation_id);


--
-- Name: index_asset_transactions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_transactions_on_created_by_id ON public.asset_transactions USING btree (created_by_id);


--
-- Name: index_asset_transactions_on_depreciation_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_transactions_on_depreciation_run_id ON public.asset_transactions USING btree (depreciation_run_id);


--
-- Name: index_asset_transactions_on_fixed_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_transactions_on_fixed_asset_id ON public.asset_transactions USING btree (fixed_asset_id);


--
-- Name: index_asset_transactions_on_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_transactions_on_history ON public.asset_transactions USING btree (tenant_id, fixed_asset_id, valuation_code, asset_value_date);


--
-- Name: index_asset_transactions_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_asset_transactions_on_idempotency ON public.asset_transactions USING btree (tenant_id, idempotency_key, valuation_code);


--
-- Name: index_asset_valuation_terms_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_valuation_terms_on_created_by_id ON public.asset_valuation_terms USING btree (created_by_id);


--
-- Name: index_asset_valuation_terms_on_created_domain_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_valuation_terms_on_created_domain_event_id ON public.asset_valuation_terms USING btree (created_domain_event_id);


--
-- Name: index_asset_valuation_terms_on_fixed_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_valuation_terms_on_fixed_asset_id ON public.asset_valuation_terms USING btree (fixed_asset_id);


--
-- Name: index_asset_valuations_on_asset_valuation_term_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_valuations_on_asset_valuation_term_id ON public.asset_valuations USING btree (asset_valuation_term_id);


--
-- Name: index_asset_valuations_on_fixed_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_asset_valuations_on_fixed_asset_id ON public.asset_valuations USING btree (fixed_asset_id);


--
-- Name: index_asset_valuations_on_view; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_asset_valuations_on_view ON public.asset_valuations USING btree (tenant_id, fixed_asset_id, valuation_code);


--
-- Name: index_bank_statement_imports_on_account_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_imports_on_account_period ON public.bank_statement_imports USING btree (tenant_id, bank_account_code, statement_to);


--
-- Name: index_bank_statement_imports_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_imports_on_created_by_id ON public.bank_statement_imports USING btree (created_by_id);


--
-- Name: index_bank_statement_imports_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_imports_on_entity_id ON public.bank_statement_imports USING btree (entity_id);


--
-- Name: index_bank_statement_imports_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_imports_on_office_id ON public.bank_statement_imports USING btree (office_id);


--
-- Name: index_bank_statement_imports_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bank_statement_imports_on_source ON public.bank_statement_imports USING btree (tenant_id, bank_account_code, source_sha256);


--
-- Name: index_bank_statement_lines_for_matching; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_lines_for_matching ON public.bank_statement_lines USING btree (tenant_id, status, booking_date);


--
-- Name: index_bank_statement_lines_on_import; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_lines_on_import ON public.bank_statement_lines USING btree (bank_statement_import_id);


--
-- Name: index_bank_statement_lines_on_ledger_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bank_statement_lines_on_ledger_identity ON public.bank_statement_lines USING btree (tenant_id, matched_ledger_event_id, matched_entry_line_no) WHERE (matched_ledger_event_id IS NOT NULL);


--
-- Name: index_bank_statement_lines_on_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bank_statement_lines_on_line_no ON public.bank_statement_lines USING btree (bank_statement_import_id, line_no);


--
-- Name: index_bank_statement_lines_on_matched_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bank_statement_lines_on_matched_by_id ON public.bank_statement_lines USING btree (matched_by_id);


--
-- Name: index_consolidation_elimination_runs_on_consolidation_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_elimination_runs_on_consolidation_group_id ON public.consolidation_elimination_runs USING btree (consolidation_group_id);


--
-- Name: index_consolidation_elimination_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_elimination_runs_on_created_by_id ON public.consolidation_elimination_runs USING btree (created_by_id);


--
-- Name: index_consolidation_elimination_runs_on_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_elimination_runs_on_ledger_event_id ON public.consolidation_elimination_runs USING btree (ledger_event_id);


--
-- Name: index_consolidation_eliminations_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consolidation_eliminations_on_idempotency ON public.consolidation_elimination_runs USING btree (tenant_id, idempotency_key);


--
-- Name: index_consolidation_eliminations_on_transaction; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consolidation_eliminations_on_transaction ON public.consolidation_elimination_runs USING btree (intercompany_transaction_id);


--
-- Name: index_consolidation_group_members_on_consolidation_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_group_members_on_consolidation_group_id ON public.consolidation_group_members USING btree (consolidation_group_id);


--
-- Name: index_consolidation_group_members_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_group_members_on_entity_id ON public.consolidation_group_members USING btree (entity_id);


--
-- Name: index_consolidation_groups_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_consolidation_groups_on_created_by_id ON public.consolidation_groups USING btree (created_by_id);


--
-- Name: index_consolidation_groups_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consolidation_groups_on_tenant_id_and_code ON public.consolidation_groups USING btree (tenant_id, code);


--
-- Name: index_consolidation_members_on_group_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_consolidation_members_on_group_entity ON public.consolidation_group_members USING btree (consolidation_group_id, entity_id);


--
-- Name: index_contract_allocation_lines_on_obligation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_allocation_lines_on_obligation ON public.contract_allocation_lines USING btree (contract_performance_obligation_id);


--
-- Name: index_contract_allocation_lines_on_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_allocation_lines_on_run ON public.contract_allocation_lines USING btree (contract_allocation_run_id);


--
-- Name: index_contract_allocation_lines_on_run_and_obligation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_allocation_lines_on_run_and_obligation ON public.contract_allocation_lines USING btree (contract_allocation_run_id, contract_performance_obligation_id);


--
-- Name: index_contract_allocation_runs_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_allocation_runs_on_contract_id ON public.contract_allocation_runs USING btree (contract_id);


--
-- Name: index_contract_allocation_runs_on_created_domain_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_allocation_runs_on_created_domain_event_id ON public.contract_allocation_runs USING btree (created_domain_event_id);


--
-- Name: index_contract_allocation_runs_on_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_allocation_runs_on_version ON public.contract_allocation_runs USING btree (tenant_id, contract_id, version);


--
-- Name: index_contract_milestones_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_milestones_on_contract_id ON public.contract_milestones USING btree (contract_id);


--
-- Name: index_contract_milestones_on_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_milestones_on_number ON public.contract_milestones USING btree (tenant_id, contract_performance_obligation_id, milestone_no);


--
-- Name: index_contract_milestones_on_obligation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_milestones_on_obligation ON public.contract_milestones USING btree (contract_performance_obligation_id);


--
-- Name: index_contract_number_ranges_on_series; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_number_ranges_on_series ON public.contract_number_ranges USING btree (tenant_id, entity_id, office_id, fiscal_year);


--
-- Name: index_contract_obligations_on_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_obligations_on_number ON public.contract_performance_obligations USING btree (tenant_id, contract_id, obligation_no);


--
-- Name: index_contract_performance_obligations_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_performance_obligations_on_contract_id ON public.contract_performance_obligations USING btree (contract_id);


--
-- Name: index_contract_posting_run_items_on_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_run_items_on_ledger_event_id ON public.contract_posting_run_items USING btree (ledger_event_id);


--
-- Name: index_contract_posting_run_items_on_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_run_items_on_run ON public.contract_posting_run_items USING btree (contract_posting_run_id);


--
-- Name: index_contract_posting_run_items_on_run_and_line; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_posting_run_items_on_run_and_line ON public.contract_posting_run_items USING btree (contract_posting_run_id, contract_schedule_line_id);


--
-- Name: index_contract_posting_run_items_on_schedule_line; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_run_items_on_schedule_line ON public.contract_posting_run_items USING btree (contract_schedule_line_id);


--
-- Name: index_contract_posting_runs_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_runs_on_contract_id ON public.contract_posting_runs USING btree (contract_id);


--
-- Name: index_contract_posting_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_runs_on_created_by_id ON public.contract_posting_runs USING btree (created_by_id);


--
-- Name: index_contract_posting_runs_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_posting_runs_on_idempotency ON public.contract_posting_runs USING btree (tenant_id, idempotency_key);


--
-- Name: index_contract_posting_runs_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_posting_runs_on_office_id ON public.contract_posting_runs USING btree (office_id);


--
-- Name: index_contract_schedule_lines_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedule_lines_due ON public.contract_schedule_lines USING btree (tenant_id, due_date, status);


--
-- Name: index_contract_schedule_lines_on_contract_milestone_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedule_lines_on_contract_milestone_id ON public.contract_schedule_lines USING btree (contract_milestone_id);


--
-- Name: index_contract_schedule_lines_on_contract_schedule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedule_lines_on_contract_schedule_id ON public.contract_schedule_lines USING btree (contract_schedule_id);


--
-- Name: index_contract_schedule_lines_on_posted_event; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_schedule_lines_on_posted_event ON public.contract_schedule_lines USING btree (posted_ledger_event_id) WHERE (posted_ledger_event_id IS NOT NULL);


--
-- Name: index_contract_schedule_lines_on_posted_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedule_lines_on_posted_ledger_event_id ON public.contract_schedule_lines USING btree (posted_ledger_event_id);


--
-- Name: index_contract_schedule_lines_on_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_schedule_lines_on_sequence ON public.contract_schedule_lines USING btree (contract_schedule_id, sequence);


--
-- Name: index_contract_schedules_on_allocation_line; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_allocation_line ON public.contract_schedules USING btree (contract_allocation_line_id);


--
-- Name: index_contract_schedules_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_contract_id ON public.contract_schedules USING btree (contract_id);


--
-- Name: index_contract_schedules_on_contract_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_contract_status ON public.contract_schedules USING btree (tenant_id, contract_id, status);


--
-- Name: index_contract_schedules_on_created_domain_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_created_domain_event_id ON public.contract_schedules USING btree (created_domain_event_id);


--
-- Name: index_contract_schedules_on_obligation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_obligation ON public.contract_schedules USING btree (contract_performance_obligation_id);


--
-- Name: index_contract_schedules_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contract_schedules_on_office_id ON public.contract_schedules USING btree (office_id);


--
-- Name: index_contract_schedules_on_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contract_schedules_on_version ON public.contract_schedules USING btree (tenant_id, contract_performance_obligation_id, version);


--
-- Name: index_contracts_on_created_domain_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_created_domain_event_id ON public.contracts USING btree (created_domain_event_id);


--
-- Name: index_contracts_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_entity_id ON public.contracts USING btree (entity_id);


--
-- Name: index_contracts_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_office_id ON public.contracts USING btree (office_id);


--
-- Name: index_contracts_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_party_id ON public.contracts USING btree (party_id);


--
-- Name: index_contracts_on_tenant_id_and_contract_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contracts_on_tenant_id_and_contract_number ON public.contracts USING btree (tenant_id, contract_number);


--
-- Name: index_contracts_on_tenant_id_and_notice_deadline_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_tenant_id_and_notice_deadline_date ON public.contracts USING btree (tenant_id, notice_deadline_date) WHERE (((status)::text = 'active'::text) AND (notice_deadline_date IS NOT NULL));


--
-- Name: index_contracts_on_tenant_id_and_party_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_tenant_id_and_party_id_and_status ON public.contracts USING btree (tenant_id, party_id, status);


--
-- Name: index_contracts_on_tenant_id_and_status_and_end_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contracts_on_tenant_id_and_status_and_end_date ON public.contracts USING btree (tenant_id, status, end_date);


--
-- Name: index_controlling_plan_lines_on_coordinate; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_controlling_plan_lines_on_coordinate ON public.controlling_plan_lines USING btree (tenant_id, version, fiscal_year, period_no, cost_center_id, account_code);


--
-- Name: index_controlling_plan_lines_on_cost_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_controlling_plan_lines_on_cost_center_id ON public.controlling_plan_lines USING btree (cost_center_id);


--
-- Name: index_controlling_plan_lines_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_controlling_plan_lines_on_created_by_id ON public.controlling_plan_lines USING btree (created_by_id);


--
-- Name: index_controlling_segments_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_controlling_segments_on_tenant_id_and_code ON public.controlling_segments USING btree (tenant_id, code);


--
-- Name: index_cost_centers_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cost_centers_on_entity_id ON public.cost_centers USING btree (entity_id);


--
-- Name: index_cost_centers_on_profit_center_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cost_centers_on_profit_center_id ON public.cost_centers USING btree (profit_center_id);


--
-- Name: index_cost_centers_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cost_centers_on_tenant_id_and_code ON public.cost_centers USING btree (tenant_id, code);


--
-- Name: index_depreciation_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_depreciation_runs_on_created_by_id ON public.depreciation_runs USING btree (created_by_id);


--
-- Name: index_depreciation_runs_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_depreciation_runs_on_entity_id ON public.depreciation_runs USING btree (entity_id);


--
-- Name: index_depreciation_runs_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_depreciation_runs_on_office_id ON public.depreciation_runs USING btree (office_id);


--
-- Name: index_depreciation_runs_on_tenant_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_depreciation_runs_on_tenant_id_and_idempotency_key ON public.depreciation_runs USING btree (tenant_id, idempotency_key);


--
-- Name: index_dimensions_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_dimensions_on_tenant_id_and_code ON public.dimensions USING btree (tenant_id, code);


--
-- Name: index_document_allocations_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_allocations_on_document_id ON public.document_allocations USING btree (document_id);


--
-- Name: index_document_allocations_on_document_id_and_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_allocations_on_document_id_and_line_no ON public.document_allocations USING btree (document_id, line_no);


--
-- Name: index_document_lines_on_credited_document_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_credited_document_line_id ON public.document_lines USING btree (credited_document_line_id);


--
-- Name: index_document_lines_on_debited_document_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_debited_document_line_id ON public.document_lines USING btree (debited_document_line_id);


--
-- Name: index_document_lines_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_document_id ON public.document_lines USING btree (document_id);


--
-- Name: index_document_lines_on_document_id_and_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_lines_on_document_id_and_line_no ON public.document_lines USING btree (document_id, line_no);


--
-- Name: index_document_lines_on_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_item_id ON public.document_lines USING btree (item_id);


--
-- Name: index_document_lines_on_purchase_order_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_purchase_order_line_id ON public.document_lines USING btree (purchase_order_line_id);


--
-- Name: index_document_types_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_types_on_tenant_id_and_code ON public.document_types USING btree (tenant_id, code);


--
-- Name: index_documents_on_contract_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_contract_id ON public.documents USING btree (contract_id);


--
-- Name: index_documents_on_contract_posting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_contract_posting ON public.documents USING btree (tenant_id, contract_id, posting_date, state);


--
-- Name: index_documents_on_document_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_document_type_id ON public.documents USING btree (document_type_id);


--
-- Name: index_documents_on_external_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_external_reference ON public.documents USING btree (tenant_id, entity_id, external_reference) WHERE (external_reference IS NOT NULL);


--
-- Name: index_documents_on_purchase_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_purchase_order_id ON public.documents USING btree (purchase_order_id);


--
-- Name: index_documents_on_reverses_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_reverses_document_id ON public.documents USING btree (reverses_document_id);


--
-- Name: index_documents_on_series_and_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_documents_on_series_and_number ON public.documents USING btree (tenant_id, entity_id, office_id, doc_type, fiscal_year, document_number) WHERE (document_number IS NOT NULL);


--
-- Name: index_documents_on_tds_assessment_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_tds_assessment_scope ON public.documents USING btree (tenant_id, party_id, fiscal_year, tds_section) WHERE (tds_section IS NOT NULL);


--
-- Name: index_documents_on_tenant_id_and_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_tenant_id_and_state ON public.documents USING btree (tenant_id, state);


--
-- Name: index_domain_events_on_signing_key_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_domain_events_on_signing_key_id ON public.domain_events USING btree (signing_key_id);


--
-- Name: index_domain_events_on_tenant_id_and_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_domain_events_on_tenant_id_and_action ON public.domain_events USING btree (tenant_id, action);


--
-- Name: index_domain_events_on_tenant_id_and_hash_hex; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_domain_events_on_tenant_id_and_hash_hex ON public.domain_events USING btree (tenant_id, hash_hex);


--
-- Name: index_domain_events_on_tenant_id_and_office_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_domain_events_on_tenant_id_and_office_id_and_seq ON public.domain_events USING btree (tenant_id, office_id, seq);


--
-- Name: index_domain_events_on_tenant_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_domain_events_on_tenant_id_and_seq ON public.domain_events USING btree (tenant_id, seq);


--
-- Name: index_einvoice_cancellations_on_einvoice_submission_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_einvoice_cancellations_on_einvoice_submission_id ON public.einvoice_cancellations USING btree (einvoice_submission_id);


--
-- Name: index_einvoice_cancellations_on_requested_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_einvoice_cancellations_on_requested_by_id ON public.einvoice_cancellations USING btree (requested_by_id);


--
-- Name: index_einvoice_cancellations_on_tenant_id_and_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_einvoice_cancellations_on_tenant_id_and_request_id ON public.einvoice_cancellations USING btree (tenant_id, request_id);


--
-- Name: index_einvoice_cancellations_on_tenant_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_einvoice_cancellations_on_tenant_id_and_status ON public.einvoice_cancellations USING btree (tenant_id, status);


--
-- Name: index_einvoice_submissions_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_einvoice_submissions_on_document_id ON public.einvoice_submissions USING btree (document_id);


--
-- Name: index_einvoice_submissions_on_tax_registration_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_einvoice_submissions_on_tax_registration_id ON public.einvoice_submissions USING btree (tax_registration_id);


--
-- Name: index_einvoice_submissions_on_tenant_id_and_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_einvoice_submissions_on_tenant_id_and_document_id ON public.einvoice_submissions USING btree (tenant_id, document_id);


--
-- Name: index_einvoice_submissions_on_tenant_id_and_irn; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_einvoice_submissions_on_tenant_id_and_irn ON public.einvoice_submissions USING btree (tenant_id, irn) WHERE (irn IS NOT NULL);


--
-- Name: index_einvoice_submissions_on_tenant_id_and_request_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_einvoice_submissions_on_tenant_id_and_request_id ON public.einvoice_submissions USING btree (tenant_id, request_id);


--
-- Name: index_einvoice_submissions_on_tenant_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_einvoice_submissions_on_tenant_id_and_status ON public.einvoice_submissions USING btree (tenant_id, status);


--
-- Name: index_entities_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_entities_on_tenant_id_and_code ON public.entities USING btree (tenant_id, code);


--
-- Name: index_entries_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entries_on_document_id ON public.entries USING btree (document_id);


--
-- Name: index_entries_on_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entries_on_ledger_event_id ON public.entries USING btree (ledger_event_id);


--
-- Name: index_entries_on_reverses_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entries_on_reverses_id ON public.entries USING btree (reverses_id);


--
-- Name: index_entries_on_tenant_document_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_entries_on_tenant_document_unique ON public.entries USING btree (tenant_id, document_id) WHERE (document_id IS NOT NULL);


--
-- Name: index_entries_on_tenant_event_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_entries_on_tenant_event_unique ON public.entries USING btree (tenant_id, ledger_event_id) WHERE (ledger_event_id IS NOT NULL);


--
-- Name: index_entries_on_tenant_id_and_fiscal_year_and_period_no; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entries_on_tenant_id_and_fiscal_year_and_period_no ON public.entries USING btree (tenant_id, fiscal_year, period_no);


--
-- Name: index_entry_lines_on_clearing_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_clearing_key ON public.entry_lines USING btree (tenant_id, assignment) WHERE (assignment IS NOT NULL);


--
-- Name: index_entry_lines_on_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_entry_id ON public.entry_lines USING btree (entry_id);


--
-- Name: index_entry_lines_on_entry_ledger_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_entry_lines_on_entry_ledger_line_no ON public.entry_lines USING btree (entry_id, ledger_id, line_no);


--
-- Name: index_entry_lines_on_fixed_asset_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_fixed_asset_id ON public.entry_lines USING btree (fixed_asset_id);


--
-- Name: index_entry_lines_on_ledger_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_ledger_id ON public.entry_lines USING btree (ledger_id);


--
-- Name: index_entry_lines_on_open_items; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_open_items ON public.entry_lines USING btree (tenant_id, assignment) WHERE (open_item AND (cleared_on IS NULL));


--
-- Name: index_entry_lines_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_party_id ON public.entry_lines USING btree (party_id);


--
-- Name: index_entry_lines_on_source_ledger_line_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_source_ledger_line_key ON public.entry_lines USING btree (tenant_id, source_event_id, ledger_id, line_no);


--
-- Name: index_entry_lines_on_tenant_id_and_account_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_tenant_id_and_account_code ON public.entry_lines USING btree (tenant_id, account_code);


--
-- Name: index_exchange_rates_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_rates_on_created_by_id ON public.exchange_rates USING btree (created_by_id);


--
-- Name: index_exchange_rates_on_governed_series; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_exchange_rates_on_governed_series ON public.exchange_rates USING btree (tenant_id, from_currency, to_currency, rate_type, effective_on);


--
-- Name: index_exchange_revaluation_items_on_exchange_rate_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_items_on_exchange_rate_id ON public.exchange_revaluation_items USING btree (exchange_rate_id);


--
-- Name: index_exchange_revaluation_items_on_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_exchange_revaluation_items_on_position ON public.exchange_revaluation_items USING btree (exchange_revaluation_run_id, account_code, foreign_currency);


--
-- Name: index_exchange_revaluation_items_on_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_items_on_run ON public.exchange_revaluation_items USING btree (exchange_revaluation_run_id);


--
-- Name: index_exchange_revaluation_runs_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_runs_on_created_by_id ON public.exchange_revaluation_runs USING btree (created_by_id);


--
-- Name: index_exchange_revaluation_runs_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_runs_on_entity_id ON public.exchange_revaluation_runs USING btree (entity_id);


--
-- Name: index_exchange_revaluation_runs_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_exchange_revaluation_runs_on_idempotency ON public.exchange_revaluation_runs USING btree (tenant_id, idempotency_key);


--
-- Name: index_exchange_revaluation_runs_on_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_runs_on_ledger_event_id ON public.exchange_revaluation_runs USING btree (ledger_event_id);


--
-- Name: index_exchange_revaluation_runs_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_exchange_revaluation_runs_on_office_id ON public.exchange_revaluation_runs USING btree (office_id);


--
-- Name: index_financial_statement_assignments_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_financial_statement_assignments_on_account_id ON public.financial_statement_assignments USING btree (account_id);


--
-- Name: index_fixed_assets_on_asset_class_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_fixed_assets_on_asset_class_id ON public.fixed_assets USING btree (asset_class_id);


--
-- Name: index_fixed_assets_on_component_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_fixed_assets_on_component_identity ON public.fixed_assets USING btree (tenant_id, asset_number, component_number);


--
-- Name: index_fixed_assets_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_fixed_assets_on_created_by_id ON public.fixed_assets USING btree (created_by_id);


--
-- Name: index_fixed_assets_on_created_domain_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_fixed_assets_on_created_domain_event_id ON public.fixed_assets USING btree (created_domain_event_id);


--
-- Name: index_fixed_assets_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_fixed_assets_on_entity_id ON public.fixed_assets USING btree (entity_id);


--
-- Name: index_fixed_assets_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_fixed_assets_on_office_id ON public.fixed_assets USING btree (office_id);


--
-- Name: index_goods_receipt_lines_on_goods_receipt_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_goods_receipt_lines_on_goods_receipt_id ON public.goods_receipt_lines USING btree (goods_receipt_id);


--
-- Name: index_goods_receipt_lines_on_inventory_transaction_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_goods_receipt_lines_on_inventory_transaction_id ON public.goods_receipt_lines USING btree (inventory_transaction_id);


--
-- Name: index_goods_receipt_lines_on_order_line; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_goods_receipt_lines_on_order_line ON public.goods_receipt_lines USING btree (goods_receipt_id, purchase_order_line_id);


--
-- Name: index_goods_receipt_lines_on_purchase_order_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_goods_receipt_lines_on_purchase_order_line_id ON public.goods_receipt_lines USING btree (purchase_order_line_id);


--
-- Name: index_goods_receipts_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_goods_receipts_on_created_by_id ON public.goods_receipts USING btree (created_by_id);


--
-- Name: index_goods_receipts_on_purchase_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_goods_receipts_on_purchase_order_id ON public.goods_receipts USING btree (purchase_order_id);


--
-- Name: index_goods_receipts_on_tenant_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_goods_receipts_on_tenant_id_and_idempotency_key ON public.goods_receipts USING btree (tenant_id, idempotency_key);


--
-- Name: index_goods_receipts_on_tenant_id_and_receipt_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_goods_receipts_on_tenant_id_and_receipt_number ON public.goods_receipts USING btree (tenant_id, receipt_number);


--
-- Name: index_intercompany_transactions_on_buyer_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercompany_transactions_on_buyer_entity_id ON public.intercompany_transactions USING btree (buyer_entity_id);


--
-- Name: index_intercompany_transactions_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercompany_transactions_on_code ON public.intercompany_transactions USING btree (tenant_id, transaction_code);


--
-- Name: index_intercompany_transactions_on_consolidation_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercompany_transactions_on_consolidation_group_id ON public.intercompany_transactions USING btree (consolidation_group_id);


--
-- Name: index_intercompany_transactions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercompany_transactions_on_created_by_id ON public.intercompany_transactions USING btree (created_by_id);


--
-- Name: index_intercompany_transactions_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_intercompany_transactions_on_idempotency ON public.intercompany_transactions USING btree (tenant_id, idempotency_key);


--
-- Name: index_intercompany_transactions_on_ledger_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercompany_transactions_on_ledger_event_id ON public.intercompany_transactions USING btree (ledger_event_id);


--
-- Name: index_intercompany_transactions_on_seller_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_intercompany_transactions_on_seller_entity_id ON public.intercompany_transactions USING btree (seller_entity_id);


--
-- Name: index_inventory_movements_on_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_movements_on_item_id ON public.inventory_movements USING btree (item_id);


--
-- Name: index_inventory_movements_on_ledger_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inventory_movements_on_ledger_identity ON public.inventory_movements USING btree (tenant_id, ledger_event_id, entry_line_no);


--
-- Name: index_inventory_movements_on_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_movements_on_position ON public.inventory_movements USING btree (tenant_id, item_id, warehouse_id, id);


--
-- Name: index_inventory_movements_on_transaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_movements_on_transaction ON public.inventory_movements USING btree (inventory_transaction_id);


--
-- Name: index_inventory_movements_on_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_movements_on_warehouse_id ON public.inventory_movements USING btree (warehouse_id);


--
-- Name: index_inventory_transactions_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_created_by_id ON public.inventory_transactions USING btree (created_by_id);


--
-- Name: index_inventory_transactions_on_destination_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_destination_warehouse_id ON public.inventory_transactions USING btree (destination_warehouse_id);


--
-- Name: index_inventory_transactions_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_entity_id ON public.inventory_transactions USING btree (entity_id);


--
-- Name: index_inventory_transactions_on_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inventory_transactions_on_idempotency ON public.inventory_transactions USING btree (tenant_id, idempotency_key);


--
-- Name: index_inventory_transactions_on_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_item_id ON public.inventory_transactions USING btree (item_id);


--
-- Name: index_inventory_transactions_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_office_id ON public.inventory_transactions USING btree (office_id);


--
-- Name: index_inventory_transactions_on_posting_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_posting_date ON public.inventory_transactions USING btree (tenant_id, posting_date);


--
-- Name: index_inventory_transactions_on_source_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_transactions_on_source_warehouse_id ON public.inventory_transactions USING btree (source_warehouse_id);


--
-- Name: index_invitations_on_one_pending_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invitations_on_one_pending_email ON public.invitations USING btree (tenant_id, email) WHERE (accepted_at IS NULL);


--
-- Name: index_items_on_tenant_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_items_on_tenant_id_and_active ON public.items USING btree (tenant_id, active);


--
-- Name: index_items_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_items_on_tenant_id_and_code ON public.items USING btree (tenant_id, code);


--
-- Name: index_jela_on_line_and_slot; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_jela_on_line_and_slot ON public.journal_entry_line_amounts USING btree (entry_line_id, slot_role);


--
-- Name: index_journal_entry_line_amounts_on_entry_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_journal_entry_line_amounts_on_entry_line_id ON public.journal_entry_line_amounts USING btree (entry_line_id);


--
-- Name: index_ledger_events_on_signing_key_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_events_on_signing_key_id ON public.ledger_events USING btree (signing_key_id);


--
-- Name: index_ledger_events_on_tenant_id_and_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_events_on_tenant_id_and_action ON public.ledger_events USING btree (tenant_id, action);


--
-- Name: index_ledger_events_on_tenant_id_and_hash_hex; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledger_events_on_tenant_id_and_hash_hex ON public.ledger_events USING btree (tenant_id, hash_hex);


--
-- Name: index_ledger_events_on_tenant_id_and_office_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_events_on_tenant_id_and_office_id_and_seq ON public.ledger_events USING btree (tenant_id, office_id, seq);


--
-- Name: index_ledger_events_on_tenant_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledger_events_on_tenant_id_and_seq ON public.ledger_events USING btree (tenant_id, seq);


--
-- Name: index_ledgers_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledgers_on_tenant_id_and_code ON public.ledgers USING btree (tenant_id, code);


--
-- Name: index_memberships_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_tenant_id ON public.memberships USING btree (tenant_id);


--
-- Name: index_memberships_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_user_id ON public.memberships USING btree (user_id);


--
-- Name: index_memberships_on_user_id_and_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_user_id_and_tenant_id ON public.memberships USING btree (user_id, tenant_id);


--
-- Name: index_number_ranges_on_series_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_number_ranges_on_series_key ON public.number_ranges USING btree (tenant_id, entity_id, office_id, doc_type, fiscal_year);


--
-- Name: index_office_tax_registrations_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_office_tax_registrations_on_office_id ON public.office_tax_registrations USING btree (office_id);


--
-- Name: index_office_tax_registrations_on_tax_registration_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_office_tax_registrations_on_tax_registration_id ON public.office_tax_registrations USING btree (tax_registration_id);


--
-- Name: index_offices_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_offices_on_entity_id ON public.offices USING btree (entity_id);


--
-- Name: index_offices_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_offices_on_tenant_id_and_code ON public.offices USING btree (tenant_id, code);


--
-- Name: index_parties_on_tenant_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_parties_on_tenant_id_and_active ON public.parties USING btree (tenant_id, active);


--
-- Name: index_parties_on_tenant_id_and_party_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_parties_on_tenant_id_and_party_number ON public.parties USING btree (tenant_id, party_number);


--
-- Name: index_party_roles_on_party_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_party_roles_on_party_id_and_role ON public.party_roles USING btree (party_id, role);


--
-- Name: index_party_tax_registrations_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_party_tax_registrations_on_party_id ON public.party_tax_registrations USING btree (party_id);


--
-- Name: index_period_controls_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_period_controls_on_scope ON public.period_controls USING btree (tenant_id, entity_id, ledger_id, fiscal_year, period_no, account_class, domain);


--
-- Name: index_procurement_matches_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_procurement_matches_on_document_id ON public.procurement_matches USING btree (document_id);


--
-- Name: index_procurement_matches_on_document_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_procurement_matches_on_document_line_id ON public.procurement_matches USING btree (document_line_id);


--
-- Name: index_procurement_matches_on_purchase_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_procurement_matches_on_purchase_order_id ON public.procurement_matches USING btree (purchase_order_id);


--
-- Name: index_procurement_matches_on_purchase_order_line_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_procurement_matches_on_purchase_order_line_id ON public.procurement_matches USING btree (purchase_order_line_id);


--
-- Name: index_profit_centers_on_controlling_segment_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_profit_centers_on_controlling_segment_id ON public.profit_centers USING btree (controlling_segment_id);


--
-- Name: index_profit_centers_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_profit_centers_on_entity_id ON public.profit_centers USING btree (entity_id);


--
-- Name: index_profit_centers_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_profit_centers_on_tenant_id_and_code ON public.profit_centers USING btree (tenant_id, code);


--
-- Name: index_purchase_order_lines_on_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_order_lines_on_item_id ON public.purchase_order_lines USING btree (item_id);


--
-- Name: index_purchase_order_lines_on_purchase_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_order_lines_on_purchase_order_id ON public.purchase_order_lines USING btree (purchase_order_id);


--
-- Name: index_purchase_order_lines_on_purchase_order_id_and_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_purchase_order_lines_on_purchase_order_id_and_line_no ON public.purchase_order_lines USING btree (purchase_order_id, line_no);


--
-- Name: index_purchase_order_lines_on_unique_item; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_purchase_order_lines_on_unique_item ON public.purchase_order_lines USING btree (purchase_order_id, item_id);


--
-- Name: index_purchase_order_lines_on_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_order_lines_on_warehouse_id ON public.purchase_order_lines USING btree (warehouse_id);


--
-- Name: index_purchase_order_number_ranges_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_order_number_ranges_on_entity_id ON public.purchase_order_number_ranges USING btree (entity_id);


--
-- Name: index_purchase_order_number_ranges_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_order_number_ranges_on_office_id ON public.purchase_order_number_ranges USING btree (office_id);


--
-- Name: index_purchase_order_ranges_on_series; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_purchase_order_ranges_on_series ON public.purchase_order_number_ranges USING btree (tenant_id, entity_id, office_id, fiscal_year);


--
-- Name: index_purchase_orders_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_approved_by_id ON public.purchase_orders USING btree (approved_by_id);


--
-- Name: index_purchase_orders_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_created_by_id ON public.purchase_orders USING btree (created_by_id);


--
-- Name: index_purchase_orders_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_entity_id ON public.purchase_orders USING btree (entity_id);


--
-- Name: index_purchase_orders_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_office_id ON public.purchase_orders USING btree (office_id);


--
-- Name: index_purchase_orders_on_tenant_id_and_order_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_purchase_orders_on_tenant_id_and_order_number ON public.purchase_orders USING btree (tenant_id, order_number);


--
-- Name: index_purchase_orders_on_tenant_id_and_status_and_order_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_tenant_id_and_status_and_order_date ON public.purchase_orders USING btree (tenant_id, status, order_date);


--
-- Name: index_purchase_orders_on_vendor_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_purchase_orders_on_vendor_profile_id ON public.purchase_orders USING btree (vendor_profile_id);


--
-- Name: index_role_permissions_on_role_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_role_permissions_on_role_template_id ON public.role_permissions USING btree (role_template_id);


--
-- Name: index_role_permissions_on_role_template_id_and_capability; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_role_permissions_on_role_template_id_and_capability ON public.role_permissions USING btree (role_template_id, capability);


--
-- Name: index_role_templates_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_role_templates_on_tenant_id_and_code ON public.role_templates USING btree (tenant_id, code);


--
-- Name: index_sessions_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_settlement_reallocations_on_document_allocation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_settlement_reallocations_on_document_allocation_id ON public.settlement_reallocations USING btree (document_allocation_id);


--
-- Name: index_sod_conflict_rules_on_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sod_conflict_rules_on_tenant_id ON public.sod_conflict_rules USING btree (tenant_id);


--
-- Name: index_sod_conflict_rules_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sod_conflict_rules_on_tenant_id_and_code ON public.sod_conflict_rules USING btree (tenant_id, code);


--
-- Name: index_stock_balances_on_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_balances_on_item_id ON public.stock_balances USING btree (item_id);


--
-- Name: index_stock_balances_on_position; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stock_balances_on_position ON public.stock_balances USING btree (tenant_id, item_id, warehouse_id);


--
-- Name: index_stock_balances_on_warehouse_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stock_balances_on_warehouse_id ON public.stock_balances USING btree (warehouse_id);


--
-- Name: index_tax_registrations_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_entity_id ON public.tax_registrations USING btree (entity_id);


--
-- Name: index_tax_registrations_on_tenant_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_tenant_id_and_active ON public.tax_registrations USING btree (tenant_id, active);


--
-- Name: index_tds_deductions_on_reverses_tds_deduction_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tds_deductions_on_reverses_tds_deduction_id ON public.tds_deductions USING btree (reverses_tds_deduction_id);


--
-- Name: index_tds_deductions_on_source_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tds_deductions_on_source_document_id ON public.tds_deductions USING btree (source_document_id);


--
-- Name: index_tds_deductions_on_tenant_id_and_fiscal_year_and_quarter; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tds_deductions_on_tenant_id_and_fiscal_year_and_quarter ON public.tds_deductions USING btree (tenant_id, fiscal_year, quarter);


--
-- Name: index_tds_deductions_on_tenant_id_and_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tds_deductions_on_tenant_id_and_party_id ON public.tds_deductions USING btree (tenant_id, party_id);


--
-- Name: index_tds_deductions_on_tenant_id_and_section; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tds_deductions_on_tenant_id_and_section ON public.tds_deductions USING btree (tenant_id, section);


--
-- Name: index_tds_deductions_on_tenant_id_and_source_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tds_deductions_on_tenant_id_and_source_document_id ON public.tds_deductions USING btree (tenant_id, source_document_id);


--
-- Name: index_tenants_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tenants_on_slug ON public.tenants USING btree (slug);


--
-- Name: index_user_office_roles_on_role_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_office_roles_on_role_template_id ON public.user_office_roles USING btree (role_template_id);


--
-- Name: index_user_office_roles_on_tenant_wide_assignment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_office_roles_on_tenant_wide_assignment ON public.user_office_roles USING btree (user_id, tenant_id) WHERE (office_id IS NULL);


--
-- Name: index_user_office_roles_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_office_roles_on_user_id ON public.user_office_roles USING btree (user_id);


--
-- Name: index_user_office_roles_on_user_tenant_office; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_office_roles_on_user_tenant_office ON public.user_office_roles USING btree (user_id, tenant_id, office_id);


--
-- Name: index_user_signing_keys_on_active_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_signing_keys_on_active_user ON public.user_signing_keys USING btree (user_id) WHERE (active = true);


--
-- Name: index_user_signing_keys_on_fingerprint; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_signing_keys_on_fingerprint ON public.user_signing_keys USING btree (fingerprint);


--
-- Name: index_user_signing_keys_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_user_signing_keys_on_user_id ON public.user_signing_keys USING btree (user_id);


--
-- Name: index_user_signing_keys_on_user_id_and_key_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_user_signing_keys_on_user_id_and_key_version ON public.user_signing_keys USING btree (user_id, key_version);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_vendor_profiles_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_profiles_on_approved_by_id ON public.vendor_profiles USING btree (approved_by_id);


--
-- Name: index_vendor_profiles_on_created_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_profiles_on_created_by_id ON public.vendor_profiles USING btree (created_by_id);


--
-- Name: index_vendor_profiles_on_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_vendor_profiles_on_party_id ON public.vendor_profiles USING btree (party_id);


--
-- Name: index_vendor_profiles_on_tenant_id_and_party_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_vendor_profiles_on_tenant_id_and_party_id ON public.vendor_profiles USING btree (tenant_id, party_id);


--
-- Name: index_warehouses_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_warehouses_on_entity_id ON public.warehouses USING btree (entity_id);


--
-- Name: index_warehouses_on_office_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_warehouses_on_office_id ON public.warehouses USING btree (office_id);


--
-- Name: index_warehouses_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_warehouses_on_tenant_id_and_code ON public.warehouses USING btree (tenant_id, code);


--
-- Name: access_review_attestations access_review_attestations_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER access_review_attestations_immutable BEFORE DELETE OR UPDATE ON public.access_review_attestations FOR EACH ROW EXECUTE FUNCTION public.folio_access_review_evidence_immutable();


--
-- Name: access_review_runs access_review_runs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER access_review_runs_immutable BEFORE DELETE OR UPDATE ON public.access_review_runs FOR EACH ROW EXECUTE FUNCTION public.folio_access_review_evidence_immutable();


--
-- Name: allocation_run_items allocation_run_items_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER allocation_run_items_immutable BEFORE DELETE OR UPDATE ON public.allocation_run_items FOR EACH ROW EXECUTE FUNCTION public.folio_controlling_evidence_immutable();


--
-- Name: allocation_runs allocation_runs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER allocation_runs_immutable BEFORE DELETE OR UPDATE ON public.allocation_runs FOR EACH ROW EXECUTE FUNCTION public.folio_controlling_evidence_immutable();


--
-- Name: asset_transactions asset_transactions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER asset_transactions_immutable BEFORE DELETE OR UPDATE ON public.asset_transactions FOR EACH ROW EXECUTE FUNCTION public.folio_asset_evidence_immutable();


--
-- Name: consolidation_elimination_runs consolidation_elimination_runs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER consolidation_elimination_runs_immutable BEFORE DELETE OR UPDATE ON public.consolidation_elimination_runs FOR EACH ROW EXECUTE FUNCTION public.folio_consolidation_evidence_immutable();


--
-- Name: contract_allocation_lines contract_allocation_lines_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER contract_allocation_lines_immutable BEFORE DELETE OR UPDATE ON public.contract_allocation_lines FOR EACH ROW EXECUTE FUNCTION public.folio_contract_allocations_immutable();


--
-- Name: contract_allocation_runs contract_allocation_runs_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER contract_allocation_runs_immutable BEFORE DELETE OR UPDATE ON public.contract_allocation_runs FOR EACH ROW EXECUTE FUNCTION public.folio_contract_allocations_immutable();


--
-- Name: domain_events domain_events_no_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER domain_events_no_delete BEFORE DELETE ON public.domain_events FOR EACH ROW EXECUTE FUNCTION public.folio_domain_events_append_only();


--
-- Name: domain_events domain_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER domain_events_no_truncate BEFORE TRUNCATE ON public.domain_events FOR EACH STATEMENT EXECUTE FUNCTION public.folio_domain_events_append_only();


--
-- Name: domain_events domain_events_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER domain_events_no_update BEFORE UPDATE ON public.domain_events FOR EACH ROW EXECUTE FUNCTION public.folio_domain_events_append_only();


--
-- Name: goods_receipt_lines goods_receipt_lines_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER goods_receipt_lines_immutable BEFORE DELETE OR UPDATE ON public.goods_receipt_lines FOR EACH ROW EXECUTE FUNCTION public.folio_procurement_evidence_immutable();


--
-- Name: goods_receipts goods_receipts_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER goods_receipts_immutable BEFORE DELETE OR UPDATE ON public.goods_receipts FOR EACH ROW EXECUTE FUNCTION public.folio_procurement_evidence_immutable();


--
-- Name: intercompany_transactions intercompany_transactions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER intercompany_transactions_immutable BEFORE DELETE OR UPDATE ON public.intercompany_transactions FOR EACH ROW EXECUTE FUNCTION public.folio_consolidation_evidence_immutable();


--
-- Name: inventory_movements inventory_movements_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inventory_movements_immutable BEFORE DELETE OR UPDATE ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.folio_inventory_evidence_immutable();


--
-- Name: inventory_transactions inventory_transactions_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER inventory_transactions_immutable BEFORE DELETE OR UPDATE ON public.inventory_transactions FOR EACH ROW EXECUTE FUNCTION public.folio_inventory_evidence_immutable();


--
-- Name: ledger_events ledger_events_no_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_delete BEFORE DELETE ON public.ledger_events FOR EACH ROW EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- Name: ledger_events ledger_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_truncate BEFORE TRUNCATE ON public.ledger_events FOR EACH STATEMENT EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- Name: ledger_events ledger_events_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_update BEFORE UPDATE ON public.ledger_events FOR EACH ROW EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- Name: user_office_roles protect_last_tenant_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_last_tenant_owner BEFORE DELETE OR UPDATE ON public.user_office_roles FOR EACH ROW EXECUTE FUNCTION public.folio_protect_last_tenant_owner();


--
-- Name: allocation_cycles fk_rails_006403eb83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_cycles
    ADD CONSTRAINT fk_rails_006403eb83 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: einvoice_submissions fk_rails_017120e64f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_submissions
    ADD CONSTRAINT fk_rails_017120e64f FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: office_tax_registrations fk_rails_019bb5b0bc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.office_tax_registrations
    ADD CONSTRAINT fk_rails_019bb5b0bc FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: bank_statement_imports fk_rails_01d7729921; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_imports
    ADD CONSTRAINT fk_rails_01d7729921 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: consolidation_elimination_runs fk_rails_0342a573f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_elimination_runs
    ADD CONSTRAINT fk_rails_0342a573f2 FOREIGN KEY (consolidation_group_id) REFERENCES public.consolidation_groups(id);


--
-- Name: contracts fk_rails_0475753257; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT fk_rails_0475753257 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: allocation_runs fk_rails_0859381c9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_runs
    ADD CONSTRAINT fk_rails_0859381c9d FOREIGN KEY (allocation_cycle_id) REFERENCES public.allocation_cycles(id);


--
-- Name: consolidation_elimination_runs fk_rails_088ec40727; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_elimination_runs
    ADD CONSTRAINT fk_rails_088ec40727 FOREIGN KEY (intercompany_transaction_id) REFERENCES public.intercompany_transactions(id);


--
-- Name: bank_statement_lines fk_rails_09ef2d0540; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_lines
    ADD CONSTRAINT fk_rails_09ef2d0540 FOREIGN KEY (matched_by_id) REFERENCES public.users(id);


--
-- Name: role_permissions fk_rails_0b72cb6964; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT fk_rails_0b72cb6964 FOREIGN KEY (role_template_id) REFERENCES public.role_templates(id);


--
-- Name: contract_posting_run_items fk_rails_0bde27ef72; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_run_items
    ADD CONSTRAINT fk_rails_0bde27ef72 FOREIGN KEY (contract_schedule_line_id) REFERENCES public.contract_schedule_lines(id);


--
-- Name: procurement_matches fk_rails_0c8a993869; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches
    ADD CONSTRAINT fk_rails_0c8a993869 FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id);


--
-- Name: user_office_roles fk_rails_1018c65b31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_rails_1018c65b31 FOREIGN KEY (role_template_id) REFERENCES public.role_templates(id);


--
-- Name: intercompany_transactions fk_rails_135e87a341; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions
    ADD CONSTRAINT fk_rails_135e87a341 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: asset_valuation_terms fk_rails_137e7c59b8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuation_terms
    ADD CONSTRAINT fk_rails_137e7c59b8 FOREIGN KEY (fixed_asset_id) REFERENCES public.fixed_assets(id);


--
-- Name: contract_posting_run_items fk_rails_13b10d0e3f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_run_items
    ADD CONSTRAINT fk_rails_13b10d0e3f FOREIGN KEY (contract_posting_run_id) REFERENCES public.contract_posting_runs(id);


--
-- Name: fixed_assets fk_rails_1586b3a455; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets
    ADD CONSTRAINT fk_rails_1586b3a455 FOREIGN KEY (asset_class_id) REFERENCES public.asset_classes(id);


--
-- Name: asset_valuation_terms fk_rails_1678955eff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuation_terms
    ADD CONSTRAINT fk_rails_1678955eff FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: warehouses fk_rails_18974474f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT fk_rails_18974474f2 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: purchase_order_lines fk_rails_1d0d709115; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT fk_rails_1d0d709115 FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: entry_lines fk_rails_1d40e13a42; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entry_lines
    ADD CONSTRAINT fk_rails_1d40e13a42 FOREIGN KEY (fixed_asset_id) REFERENCES public.fixed_assets(id);


--
-- Name: bank_statement_imports fk_rails_1d4ecd5563; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_imports
    ADD CONSTRAINT fk_rails_1d4ecd5563 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: goods_receipts fk_rails_1e4a00dae7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT fk_rails_1e4a00dae7 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: vendor_profiles fk_rails_1eeb109c2f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_profiles
    ADD CONSTRAINT fk_rails_1eeb109c2f FOREIGN KEY (approved_by_id) REFERENCES public.users(id);


--
-- Name: contract_schedule_lines fk_rails_210e54af8e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedule_lines
    ADD CONSTRAINT fk_rails_210e54af8e FOREIGN KEY (contract_schedule_id) REFERENCES public.contract_schedules(id);


--
-- Name: financial_statement_assignments fk_rails_260071ca82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_260071ca82 FOREIGN KEY (financial_statement_version_id) REFERENCES public.financial_statement_versions(id);


--
-- Name: contract_schedules fk_rails_29fd715d70; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules
    ADD CONSTRAINT fk_rails_29fd715d70 FOREIGN KEY (contract_allocation_line_id) REFERENCES public.contract_allocation_lines(id);


--
-- Name: asset_valuations fk_rails_2e18d9c8af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuations
    ADD CONSTRAINT fk_rails_2e18d9c8af FOREIGN KEY (fixed_asset_id) REFERENCES public.fixed_assets(id);


--
-- Name: financial_statement_assignments fk_rails_2e41516b26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_2e41516b26 FOREIGN KEY (financial_statement_section_id) REFERENCES public.financial_statement_sections(id);


--
-- Name: depreciation_runs fk_rails_3043c4acf0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.depreciation_runs
    ADD CONSTRAINT fk_rails_3043c4acf0 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: office_tax_registrations fk_rails_341ce49cc2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.office_tax_registrations
    ADD CONSTRAINT fk_rails_341ce49cc2 FOREIGN KEY (tax_registration_id) REFERENCES public.tax_registrations(id);


--
-- Name: profit_centers fk_rails_347123f6e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_centers
    ADD CONSTRAINT fk_rails_347123f6e9 FOREIGN KEY (controlling_segment_id) REFERENCES public.controlling_segments(id);


--
-- Name: allocation_cycles fk_rails_34eb2dc812; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_cycles
    ADD CONSTRAINT fk_rails_34eb2dc812 FOREIGN KEY (sender_cost_center_id) REFERENCES public.cost_centers(id);


--
-- Name: exchange_rates fk_rails_3908165cb0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_rates
    ADD CONSTRAINT fk_rails_3908165cb0 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: purchase_orders fk_rails_3c1ce09582; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_rails_3c1ce09582 FOREIGN KEY (approved_by_id) REFERENCES public.users(id);


--
-- Name: einvoice_cancellations fk_rails_3d5576b900; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations
    ADD CONSTRAINT fk_rails_3d5576b900 FOREIGN KEY (einvoice_submission_id) REFERENCES public.einvoice_submissions(id);


--
-- Name: inventory_transactions fk_rails_3e52066ab5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_3e52066ab5 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: contract_posting_runs fk_rails_3f0a2896ad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_runs
    ADD CONSTRAINT fk_rails_3f0a2896ad FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: einvoice_cancellations fk_rails_40be4a3449; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations
    ADD CONSTRAINT fk_rails_40be4a3449 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: allocation_run_items fk_rails_4128d48bcd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_run_items
    ADD CONSTRAINT fk_rails_4128d48bcd FOREIGN KEY (allocation_run_id) REFERENCES public.allocation_runs(id);


--
-- Name: einvoice_submissions fk_rails_41f91a62ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_submissions
    ADD CONSTRAINT fk_rails_41f91a62ff FOREIGN KEY (tax_registration_id) REFERENCES public.tax_registrations(id);


--
-- Name: exchange_revaluation_runs fk_rails_423a47e852; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_runs
    ADD CONSTRAINT fk_rails_423a47e852 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: allocation_receivers fk_rails_4280ec531a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_receivers
    ADD CONSTRAINT fk_rails_4280ec531a FOREIGN KEY (allocation_cycle_id) REFERENCES public.allocation_cycles(id);


--
-- Name: consolidation_elimination_runs fk_rails_42e60aa5cf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_elimination_runs
    ADD CONSTRAINT fk_rails_42e60aa5cf FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: bank_statement_lines fk_rails_43220de1f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_lines
    ADD CONSTRAINT fk_rails_43220de1f5 FOREIGN KEY (bank_statement_import_id) REFERENCES public.bank_statement_imports(id);


--
-- Name: exchange_revaluation_runs fk_rails_43ce24d3c7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_runs
    ADD CONSTRAINT fk_rails_43ce24d3c7 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: intercompany_transactions fk_rails_44ae468242; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions
    ADD CONSTRAINT fk_rails_44ae468242 FOREIGN KEY (consolidation_group_id) REFERENCES public.consolidation_groups(id);


--
-- Name: access_review_attestations fk_rails_457eb4387c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_attestations
    ADD CONSTRAINT fk_rails_457eb4387c FOREIGN KEY (attested_by_id) REFERENCES public.users(id);


--
-- Name: allocation_run_items fk_rails_481502944d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_run_items
    ADD CONSTRAINT fk_rails_481502944d FOREIGN KEY (sender_cost_center_id) REFERENCES public.cost_centers(id);


--
-- Name: contract_posting_runs fk_rails_490d24d00d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_runs
    ADD CONSTRAINT fk_rails_490d24d00d FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: allocation_runs fk_rails_4fdcd44d82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_runs
    ADD CONSTRAINT fk_rails_4fdcd44d82 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: access_review_runs fk_rails_5232756c76; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_runs
    ADD CONSTRAINT fk_rails_5232756c76 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: document_allocations fk_rails_524991528c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_allocations
    ADD CONSTRAINT fk_rails_524991528c FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: exchange_revaluation_items fk_rails_53a08ec822; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_items
    ADD CONSTRAINT fk_rails_53a08ec822 FOREIGN KEY (exchange_rate_id) REFERENCES public.exchange_rates(id);


--
-- Name: goods_receipt_lines fk_rails_5c58f31f71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT fk_rails_5c58f31f71 FOREIGN KEY (inventory_transaction_id) REFERENCES public.inventory_transactions(id);


--
-- Name: bank_statement_imports fk_rails_6376db30c1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bank_statement_imports
    ADD CONSTRAINT fk_rails_6376db30c1 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: purchase_order_number_ranges fk_rails_63b9f56621; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_number_ranges
    ADD CONSTRAINT fk_rails_63b9f56621 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: inventory_transactions fk_rails_64096b371f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_64096b371f FOREIGN KEY (source_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: asset_valuations fk_rails_68c92c7954; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_valuations
    ADD CONSTRAINT fk_rails_68c92c7954 FOREIGN KEY (asset_valuation_term_id) REFERENCES public.asset_valuation_terms(id);


--
-- Name: cost_centers fk_rails_6d9c77f2cd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT fk_rails_6d9c77f2cd FOREIGN KEY (profit_center_id) REFERENCES public.profit_centers(id);


--
-- Name: asset_transactions fk_rails_6dc5e10bfe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions
    ADD CONSTRAINT fk_rails_6dc5e10bfe FOREIGN KEY (fixed_asset_id) REFERENCES public.fixed_assets(id);


--
-- Name: consolidation_group_members fk_rails_6f6d4ea122; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_group_members
    ADD CONSTRAINT fk_rails_6f6d4ea122 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: warehouses fk_rails_70cd2f2065; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT fk_rails_70cd2f2065 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: purchase_orders fk_rails_7139e543c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_rails_7139e543c2 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: contract_milestones fk_rails_730e2eaf97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_milestones
    ADD CONSTRAINT fk_rails_730e2eaf97 FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: inventory_transactions fk_rails_735685831f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_735685831f FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: contract_milestones fk_rails_754ebeb234; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_milestones
    ADD CONSTRAINT fk_rails_754ebeb234 FOREIGN KEY (contract_performance_obligation_id) REFERENCES public.contract_performance_obligations(id);


--
-- Name: cost_centers fk_rails_755747d762; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT fk_rails_755747d762 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: contracts fk_rails_767f3c1ac0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT fk_rails_767f3c1ac0 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: purchase_orders fk_rails_770688b262; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_rails_770688b262 FOREIGN KEY (vendor_profile_id) REFERENCES public.vendor_profiles(id);


--
-- Name: purchase_order_lines fk_rails_7b2f871d0c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT fk_rails_7b2f871d0c FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: user_signing_keys fk_rails_7e11dda020; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_signing_keys
    ADD CONSTRAINT fk_rails_7e11dda020 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: contracts fk_rails_7f020f7c9b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT fk_rails_7f020f7c9b FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: inventory_movements fk_rails_7f1cd89715; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT fk_rails_7f1cd89715 FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: fixed_assets fk_rails_7fe8af0c4c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets
    ADD CONSTRAINT fk_rails_7fe8af0c4c FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: access_review_attestations fk_rails_80230896e9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_attestations
    ADD CONSTRAINT fk_rails_80230896e9 FOREIGN KEY (access_review_run_id) REFERENCES public.access_review_runs(id);


--
-- Name: procurement_matches fk_rails_8422dcd887; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches
    ADD CONSTRAINT fk_rails_8422dcd887 FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: vendor_profiles fk_rails_849c428992; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_profiles
    ADD CONSTRAINT fk_rails_849c428992 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: user_office_roles fk_rails_84f904cce7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_rails_84f904cce7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: consolidation_groups fk_rails_87ef6a4fbf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_groups
    ADD CONSTRAINT fk_rails_87ef6a4fbf FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: allocation_cycles fk_rails_897630b18f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_cycles
    ADD CONSTRAINT fk_rails_897630b18f FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: asset_transactions fk_rails_89a5245dab; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions
    ADD CONSTRAINT fk_rails_89a5245dab FOREIGN KEY (asset_valuation_id) REFERENCES public.asset_valuations(id);


--
-- Name: settlement_reallocations fk_rails_8a212ab233; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_reallocations
    ADD CONSTRAINT fk_rails_8a212ab233 FOREIGN KEY (document_allocation_id) REFERENCES public.document_allocations(id);


--
-- Name: vendor_profiles fk_rails_8a44bbbdd8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vendor_profiles
    ADD CONSTRAINT fk_rails_8a44bbbdd8 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: purchase_order_number_ranges fk_rails_8dea018959; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_number_ranges
    ADD CONSTRAINT fk_rails_8dea018959 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: stock_balances fk_rails_8ff754731a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_balances
    ADD CONSTRAINT fk_rails_8ff754731a FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: contract_allocation_lines fk_rails_901065d56c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_lines
    ADD CONSTRAINT fk_rails_901065d56c FOREIGN KEY (contract_performance_obligation_id) REFERENCES public.contract_performance_obligations(id);


--
-- Name: intercompany_transactions fk_rails_9137d7f075; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions
    ADD CONSTRAINT fk_rails_9137d7f075 FOREIGN KEY (seller_entity_id) REFERENCES public.entities(id);


--
-- Name: intercompany_transactions fk_rails_93bfddda2e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.intercompany_transactions
    ADD CONSTRAINT fk_rails_93bfddda2e FOREIGN KEY (buyer_entity_id) REFERENCES public.entities(id);


--
-- Name: depreciation_runs fk_rails_94f7109ada; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.depreciation_runs
    ADD CONSTRAINT fk_rails_94f7109ada FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: inventory_transactions fk_rails_95c39ffbf9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_95c39ffbf9 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: contract_schedules fk_rails_9ac99ed8ec; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules
    ADD CONSTRAINT fk_rails_9ac99ed8ec FOREIGN KEY (contract_performance_obligation_id) REFERENCES public.contract_performance_obligations(id);


--
-- Name: inventory_transactions fk_rails_9d376b6b93; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_9d376b6b93 FOREIGN KEY (destination_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: contract_schedules fk_rails_9df590b1bb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules
    ADD CONSTRAINT fk_rails_9df590b1bb FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: goods_receipt_lines fk_rails_9f16d899e5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT fk_rails_9f16d899e5 FOREIGN KEY (purchase_order_line_id) REFERENCES public.purchase_order_lines(id);


--
-- Name: party_roles fk_rails_9fe14e5bed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_roles
    ADD CONSTRAINT fk_rails_9fe14e5bed FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: access_review_runs fk_rails_a3eff96c0a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_review_runs
    ADD CONSTRAINT fk_rails_a3eff96c0a FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: purchase_order_lines fk_rails_a4215877c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_lines
    ADD CONSTRAINT fk_rails_a4215877c0 FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id);


--
-- Name: purchase_orders fk_rails_a440a1415d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_rails_a440a1415d FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: financial_statement_assignments fk_rails_a658674e61; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_a658674e61 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: inventory_movements fk_rails_a7e956a1f6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT fk_rails_a7e956a1f6 FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: memberships fk_rails_a959f0d1fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_a959f0d1fb FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: sod_conflict_rules fk_rails_ad131fb59e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sod_conflict_rules
    ADD CONSTRAINT fk_rails_ad131fb59e FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: stock_balances fk_rails_aea4178f27; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_balances
    ADD CONSTRAINT fk_rails_aea4178f27 FOREIGN KEY (item_id) REFERENCES public.items(id);


--
-- Name: procurement_matches fk_rails_aeea4b00c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches
    ADD CONSTRAINT fk_rails_aeea4b00c9 FOREIGN KEY (document_line_id) REFERENCES public.document_lines(id);


--
-- Name: procurement_matches fk_rails_b27bba0779; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.procurement_matches
    ADD CONSTRAINT fk_rails_b27bba0779 FOREIGN KEY (purchase_order_line_id) REFERENCES public.purchase_order_lines(id);


--
-- Name: asset_transactions fk_rails_b44828b607; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions
    ADD CONSTRAINT fk_rails_b44828b607 FOREIGN KEY (depreciation_run_id) REFERENCES public.depreciation_runs(id);


--
-- Name: depreciation_runs fk_rails_b757bb7aba; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.depreciation_runs
    ADD CONSTRAINT fk_rails_b757bb7aba FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: purchase_orders fk_rails_ba72717467; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT fk_rails_ba72717467 FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: party_tax_registrations fk_rails_ba92ab1221; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_tax_registrations
    ADD CONSTRAINT fk_rails_ba92ab1221 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: goods_receipts fk_rails_bbe00c5362; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT fk_rails_bbe00c5362 FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id);


--
-- Name: contract_schedules fk_rails_bc70a72a4b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedules
    ADD CONSTRAINT fk_rails_bc70a72a4b FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: contract_allocation_lines fk_rails_bd66244221; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_lines
    ADD CONSTRAINT fk_rails_bd66244221 FOREIGN KEY (contract_allocation_run_id) REFERENCES public.contract_allocation_runs(id);


--
-- Name: controlling_plan_lines fk_rails_c2a584b4c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_plan_lines
    ADD CONSTRAINT fk_rails_c2a584b4c4 FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id);


--
-- Name: allocation_run_items fk_rails_c35d17c2e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_run_items
    ADD CONSTRAINT fk_rails_c35d17c2e7 FOREIGN KEY (receiver_cost_center_id) REFERENCES public.cost_centers(id);


--
-- Name: financial_statement_sections fk_rails_c48cc303c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections
    ADD CONSTRAINT fk_rails_c48cc303c2 FOREIGN KEY (parent_id) REFERENCES public.financial_statement_sections(id);


--
-- Name: allocation_receivers fk_rails_c67bbcc836; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allocation_receivers
    ADD CONSTRAINT fk_rails_c67bbcc836 FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id);


--
-- Name: exchange_revaluation_items fk_rails_c95c0c0030; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_items
    ADD CONSTRAINT fk_rails_c95c0c0030 FOREIGN KEY (exchange_revaluation_run_id) REFERENCES public.exchange_revaluation_runs(id);


--
-- Name: contract_posting_runs fk_rails_cef285fc3e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_posting_runs
    ADD CONSTRAINT fk_rails_cef285fc3e FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: asset_transactions fk_rails_d8285cb68e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_transactions
    ADD CONSTRAINT fk_rails_d8285cb68e FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: document_lines fk_rails_da289f4794; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_lines
    ADD CONSTRAINT fk_rails_da289f4794 FOREIGN KEY (purchase_order_line_id) REFERENCES public.purchase_order_lines(id);


--
-- Name: documents fk_rails_dd14d0c95c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_dd14d0c95c FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: exchange_revaluation_runs fk_rails_de5b7fed5a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_revaluation_runs
    ADD CONSTRAINT fk_rails_de5b7fed5a FOREIGN KEY (office_id) REFERENCES public.offices(id);


--
-- Name: fixed_assets fk_rails_dfa102c168; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets
    ADD CONSTRAINT fk_rails_dfa102c168 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: inventory_movements fk_rails_e8d059b9f1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT fk_rails_e8d059b9f1 FOREIGN KEY (inventory_transaction_id) REFERENCES public.inventory_transactions(id);


--
-- Name: inventory_transactions fk_rails_eb31e25f55; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_transactions
    ADD CONSTRAINT fk_rails_eb31e25f55 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: profit_centers fk_rails_edbffecb67; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profit_centers
    ADD CONSTRAINT fk_rails_edbffecb67 FOREIGN KEY (entity_id) REFERENCES public.entities(id);


--
-- Name: contract_performance_obligations fk_rails_ef44a79072; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_performance_obligations
    ADD CONSTRAINT fk_rails_ef44a79072 FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: goods_receipt_lines fk_rails_f2f12b04b3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_lines
    ADD CONSTRAINT fk_rails_f2f12b04b3 FOREIGN KEY (goods_receipt_id) REFERENCES public.goods_receipts(id);


--
-- Name: financial_statement_sections fk_rails_f389e55e55; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections
    ADD CONSTRAINT fk_rails_f389e55e55 FOREIGN KEY (financial_statement_version_id) REFERENCES public.financial_statement_versions(id);


--
-- Name: contract_allocation_runs fk_rails_f7d2ea3f42; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_allocation_runs
    ADD CONSTRAINT fk_rails_f7d2ea3f42 FOREIGN KEY (contract_id) REFERENCES public.contracts(id);


--
-- Name: documents fk_rails_f88f06229a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT fk_rails_f88f06229a FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id);


--
-- Name: controlling_plan_lines fk_rails_f8e9ee0273; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.controlling_plan_lines
    ADD CONSTRAINT fk_rails_f8e9ee0273 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: contract_schedule_lines fk_rails_fb04dcc75f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_schedule_lines
    ADD CONSTRAINT fk_rails_fb04dcc75f FOREIGN KEY (contract_milestone_id) REFERENCES public.contract_milestones(id);


--
-- Name: consolidation_group_members fk_rails_fc2159b0c9; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.consolidation_group_members
    ADD CONSTRAINT fk_rails_fc2159b0c9 FOREIGN KEY (consolidation_group_id) REFERENCES public.consolidation_groups(id);


--
-- Name: fixed_assets fk_rails_fc55eb6536; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_assets
    ADD CONSTRAINT fk_rails_fc55eb6536 FOREIGN KEY (created_by_id) REFERENCES public.users(id);


--
-- Name: user_office_roles fk_user_limits_same_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_user_limits_same_tenant FOREIGN KEY (posting_limit_id, tenant_id) REFERENCES public.posting_limits(id, tenant_id);


--
-- Name: user_office_roles fk_user_roles_same_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_user_roles_same_tenant FOREIGN KEY (role_template_id, tenant_id) REFERENCES public.role_templates(id, tenant_id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260801194000'),
('20260801193000'),
('20260801192000'),
('20260801191000'),
('20260801190000'),
('20260801183000'),
('20260801180000'),
('20260801173000'),
('20260801172000'),
('20260801171000'),
('20260801170000'),
('20260801165000'),
('20260801164000'),
('20260801163000'),
('20260801162000'),
('20260801161000'),
('20260801160000'),
('20260801150000'),
('20260801140000'),
('20260801130000'),
('20260801120000'),
('20260801110000'),
('20260801100000'),
('20260801008000'),
('20260801007000'),
('20260801006000'),
('20260801005000'),
('20260801004000'),
('20260801003000'),
('20260801002000'),
('20260801001000'),
('20260801000000'),
('20260731235500'),
('20260731235000'),
('20260731234000'),
('20260731233000'),
('20260731232000'),
('20260731231000'),
('20260731230000'),
('20260731220000'),
('20260731100000'),
('20260731091000'),
('20260731090000'),
('20260730230000'),
('20260729180100'),
('20260729180000'),
('20260729170000'),
('20260729160000'),
('20260729150302'),
('20260729150301'),
('20260729150300'),
('20260729150200'),
('20260729150100'),
('20260729150000'),
('20260729140000'),
('20260729130000'),
('20260729120100'),
('20260729120000'),
('20260729110500'),
('20260729110400'),
('20260729110300'),
('20260729110200'),
('20260729110100'),
('20260729110000'),
('20260729100300'),
('20260729100200'),
('20260729100100'),
('20260729100000'),
('20260728020000'),
('20260727214500');

