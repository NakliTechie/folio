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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


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
-- Name: dimensions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dimensions ALTER COLUMN id SET DEFAULT nextval('public.dimensions_id_seq'::regclass);


--
-- Name: entities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities ALTER COLUMN id SET DEFAULT nextval('public.entities_id_seq'::regclass);


--
-- Name: ledger_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_events ALTER COLUMN id SET DEFAULT nextval('public.ledger_events_id_seq'::regclass);


--
-- Name: ledgers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledgers ALTER COLUMN id SET DEFAULT nextval('public.ledgers_id_seq'::regclass);


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
-- Name: tax_registrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations ALTER COLUMN id SET DEFAULT nextval('public.tax_registrations_id_seq'::regclass);


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
-- Name: entities entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: tax_registrations tax_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tax_registrations
    ADD CONSTRAINT tax_registrations_pkey PRIMARY KEY (id);


--
-- Name: index_dimensions_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_dimensions_on_tenant_id_and_code ON public.dimensions USING btree (tenant_id, code);


--
-- Name: index_entities_on_tenant_id_and_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_entities_on_tenant_id_and_code ON public.entities USING btree (tenant_id, code);


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
-- Name: index_tax_registrations_on_entity_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_entity_id ON public.tax_registrations USING btree (entity_id);


--
-- Name: index_tax_registrations_on_tenant_id_and_kind_and_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_tax_registrations_on_tenant_id_and_kind_and_identifier ON public.tax_registrations USING btree (tenant_id, kind, identifier);


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
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260729100300'),
('20260729100200'),
('20260729100100'),
('20260729100000'),
('20260728020000'),
('20260727214500');

