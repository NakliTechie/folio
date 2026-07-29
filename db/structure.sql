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
    updated_at timestamp(6) without time zone NOT NULL
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
    updated_at timestamp(6) without time zone NOT NULL
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
    CONSTRAINT chk_documents_state CHECK (((state)::text = ANY ((ARRAY['draft'::character varying, 'parked'::character varying, 'posted'::character varying, 'reversed'::character varying])::text[])))
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
    source_event_id bigint
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
    updated_at timestamp(6) without time zone NOT NULL
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
    updated_at timestamp(6) without time zone NOT NULL
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
    updated_at timestamp(6) without time zone NOT NULL
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
    valid_from date,
    valid_to date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
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
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
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
-- Name: number_ranges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.number_ranges ALTER COLUMN id SET DEFAULT nextval('public.number_ranges_id_seq'::regclass);


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
-- Name: period_controls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.period_controls ALTER COLUMN id SET DEFAULT nextval('public.period_controls_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: tax_registrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations ALTER COLUMN id SET DEFAULT nextval('public.tax_registrations_id_seq'::regclass);


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
-- Name: number_ranges number_ranges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.number_ranges
    ADD CONSTRAINT number_ranges_pkey PRIMARY KEY (id);


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
-- Name: period_controls period_controls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.period_controls
    ADD CONSTRAINT period_controls_pkey PRIMARY KEY (id);


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
-- Name: tax_registrations tax_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations
    ADD CONSTRAINT tax_registrations_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: index_accounts_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_accounts_on_tenant_id_and_code ON public.accounts USING btree (tenant_id, code);


--
-- Name: index_dimensions_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_dimensions_on_tenant_id_and_code ON public.dimensions USING btree (tenant_id, code);


--
-- Name: index_document_lines_on_document_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_document_lines_on_document_id ON public.document_lines USING btree (document_id);


--
-- Name: index_document_lines_on_document_id_and_line_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_document_lines_on_document_id_and_line_no ON public.document_lines USING btree (document_id, line_no);


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
-- Name: index_documents_on_tenant_id_and_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_documents_on_tenant_id_and_state ON public.documents USING btree (tenant_id, state);


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
-- Name: index_entry_lines_on_source_line_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_source_line_key ON public.entry_lines USING btree (tenant_id, source_event_id, line_no);


--
-- Name: index_entry_lines_on_tenant_id_and_account_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_entry_lines_on_tenant_id_and_account_code ON public.entry_lines USING btree (tenant_id, account_code);


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
-- Name: index_number_ranges_on_series_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_number_ranges_on_series_key ON public.number_ranges USING btree (tenant_id, entity_id, office_id, doc_type, fiscal_year);


--
-- Name: index_offices_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_offices_on_entity_id ON public.offices USING btree (entity_id);


--
-- Name: index_offices_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_offices_on_tenant_id_and_code ON public.offices USING btree (tenant_id, code);


--
-- Name: index_parties_on_tenant_id_and_party_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_parties_on_tenant_id_and_party_number ON public.parties USING btree (tenant_id, party_number);


--
-- Name: index_party_roles_on_party_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_party_roles_on_party_id_and_role ON public.party_roles USING btree (party_id, role);


--
-- Name: index_period_controls_on_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_period_controls_on_scope ON public.period_controls USING btree (tenant_id, entity_id, ledger_id, fiscal_year, period_no, account_class, domain);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_tax_registrations_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_entity_id ON public.tax_registrations USING btree (entity_id);


--
-- Name: index_tax_registrations_on_tenant_id_and_kind_and_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_tenant_id_and_kind_and_identifier ON public.tax_registrations USING btree (tenant_id, kind, identifier);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


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
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
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

