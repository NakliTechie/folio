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
    active boolean DEFAULT true NOT NULL
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
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


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
    CONSTRAINT chk_items_cess_rate CHECK (((cess_rate_basis_points >= 0) AND (cess_rate_basis_points <= 10000))),
    CONSTRAINT chk_items_tax_rate CHECK (((tax_rate_basis_points >= 0) AND (tax_rate_basis_points <= 4000))),
    CONSTRAINT chk_items_type CHECK (((item_type)::text = ANY ((ARRAY['service'::character varying, 'good'::character varying])::text[])))
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
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


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
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


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
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


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
-- Name: idx_on_tenant_id_kind_identifier_valid_from_f473959005; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_tenant_id_kind_identifier_valid_from_f473959005 ON public.tax_registrations USING btree (tenant_id, kind, identifier, valid_from);


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
-- Name: index_accounts_on_tenant_id_and_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_tenant_id_and_active ON public.accounts USING btree (tenant_id, active);


--
-- Name: index_accounts_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_tenant_id_and_code ON public.accounts USING btree (tenant_id, code);


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
-- Name: index_document_types_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_types_on_tenant_id_and_code ON public.document_types USING btree (tenant_id, code);


--
-- Name: index_documents_on_document_type_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_document_type_id ON public.documents USING btree (document_type_id);


--
-- Name: index_documents_on_external_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_external_reference ON public.documents USING btree (tenant_id, entity_id, external_reference) WHERE (external_reference IS NOT NULL);


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
-- Name: index_financial_statement_assignments_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_financial_statement_assignments_on_account_id ON public.financial_statement_assignments USING btree (account_id);


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
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


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
-- Name: role_permissions fk_rails_0b72cb6964; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT fk_rails_0b72cb6964 FOREIGN KEY (role_template_id) REFERENCES public.role_templates(id);


--
-- Name: user_office_roles fk_rails_1018c65b31; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_rails_1018c65b31 FOREIGN KEY (role_template_id) REFERENCES public.role_templates(id);


--
-- Name: financial_statement_assignments fk_rails_260071ca82; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_260071ca82 FOREIGN KEY (financial_statement_version_id) REFERENCES public.financial_statement_versions(id);


--
-- Name: financial_statement_assignments fk_rails_2e41516b26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_2e41516b26 FOREIGN KEY (financial_statement_section_id) REFERENCES public.financial_statement_sections(id);


--
-- Name: office_tax_registrations fk_rails_341ce49cc2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.office_tax_registrations
    ADD CONSTRAINT fk_rails_341ce49cc2 FOREIGN KEY (tax_registration_id) REFERENCES public.tax_registrations(id);


--
-- Name: einvoice_cancellations fk_rails_3d5576b900; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations
    ADD CONSTRAINT fk_rails_3d5576b900 FOREIGN KEY (einvoice_submission_id) REFERENCES public.einvoice_submissions(id);


--
-- Name: einvoice_cancellations fk_rails_40be4a3449; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_cancellations
    ADD CONSTRAINT fk_rails_40be4a3449 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);


--
-- Name: einvoice_submissions fk_rails_41f91a62ff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.einvoice_submissions
    ADD CONSTRAINT fk_rails_41f91a62ff FOREIGN KEY (tax_registration_id) REFERENCES public.tax_registrations(id);


--
-- Name: document_allocations fk_rails_524991528c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_allocations
    ADD CONSTRAINT fk_rails_524991528c FOREIGN KEY (document_id) REFERENCES public.documents(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: user_office_roles fk_rails_84f904cce7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_office_roles
    ADD CONSTRAINT fk_rails_84f904cce7 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: settlement_reallocations fk_rails_8a212ab233; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settlement_reallocations
    ADD CONSTRAINT fk_rails_8a212ab233 FOREIGN KEY (document_allocation_id) REFERENCES public.document_allocations(id);


--
-- Name: memberships fk_rails_99326fb65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_99326fb65d FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: party_roles fk_rails_9fe14e5bed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_roles
    ADD CONSTRAINT fk_rails_9fe14e5bed FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: financial_statement_assignments fk_rails_a658674e61; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_assignments
    ADD CONSTRAINT fk_rails_a658674e61 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: memberships fk_rails_a959f0d1fb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_a959f0d1fb FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: party_tax_registrations fk_rails_ba92ab1221; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.party_tax_registrations
    ADD CONSTRAINT fk_rails_ba92ab1221 FOREIGN KEY (party_id) REFERENCES public.parties(id);


--
-- Name: financial_statement_sections fk_rails_c48cc303c2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections
    ADD CONSTRAINT fk_rails_c48cc303c2 FOREIGN KEY (parent_id) REFERENCES public.financial_statement_sections(id);


--
-- Name: financial_statement_sections fk_rails_f389e55e55; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_statement_sections
    ADD CONSTRAINT fk_rails_f389e55e55 FOREIGN KEY (financial_statement_version_id) REFERENCES public.financial_statement_versions(id);


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

