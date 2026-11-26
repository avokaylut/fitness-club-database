--
-- PostgreSQL database dump
--

\restrict ucXKl24geYk69xz9KfR8TWHHlv4jzKDMvukeTboWBMKbNMKFtZTKMX4oYFxpBux

-- Dumped from database version 17.8
-- Dumped by pg_dump version 17.8

-- Started on 2026-05-12 15:23:40

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

DROP DATABASE fit_club;
--
-- TOC entry 5012 (class 1262 OID 24957)
-- Name: fit_club; Type: DATABASE; Schema: -; Owner: postgres
--

CREATE DATABASE fit_club WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE_PROVIDER = libc LOCALE = 'Russian_Russia.1251';


ALTER DATABASE fit_club OWNER TO postgres;

\unrestrict ucXKl24geYk69xz9KfR8TWHHlv4jzKDMvukeTboWBMKbNMKFtZTKMX4oYFxpBux
\connect fit_club
\restrict ucXKl24geYk69xz9KfR8TWHHlv4jzKDMvukeTboWBMKbNMKFtZTKMX4oYFxpBux

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 250 (class 1255 OID 25163)
-- Name: автоактивация_абонемента(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."автоактивация_абонемента"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    активный_неактивированный RECORD;
BEGIN
    -- Ищем неактивированный абонемент клиента
    SELECT ка.* INTO активный_неактивированный
    FROM Клиенты_Абонементы ка
    WHERE ка.ID_клиента = NEW.ID_клиента
      AND ка.Дата_активации IS NULL
    ORDER BY ка.Дата_покупки ASC
    LIMIT 1;
    
    -- Если нашли — активируем
    IF FOUND THEN
        UPDATE Клиенты_Абонементы
        SET Дата_активации = NEW.Дата_посещения,
            Статус = 'активен'
        WHERE ID_клиента = активный_неактивированный.ID_клиента
          AND ID_абонемента = активный_неактивированный.ID_абонемента
          AND Дата_покупки = активный_неактивированный.Дата_покупки;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public."автоактивация_абонемента"() OWNER TO postgres;

--
-- TOC entry 247 (class 1255 OID 25140)
-- Name: деактивировать_старые_абонементы(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."деактивировать_старые_абонементы"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Деактивируем все другие абонементы этого клиента
    UPDATE Клиенты_Абонементы
    SET Статус = 
        CASE 
            WHEN Остаток_занятий = 0 THEN 'закончился'
            ELSE 'просрочен'
        END
    WHERE ID_клиента = NEW.ID_клиента
      AND Статус IN ('активен', 'неактивен')
      AND (ID_абонемента != NEW.ID_абонемента 
           OR (ID_абонемента = NEW.ID_абонемента AND Дата_покупки != NEW.Дата_покупки));
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public."деактивировать_старые_абонементы"() OWNER TO postgres;

--
-- TOC entry 235 (class 1255 OID 25142)
-- Name: обновить_статус_абонемента(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."обновить_статус_абонемента"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Для активных абонементов проверяем срок действия
    UPDATE Клиенты_Абонементы
    SET Статус = 'просрочен'
    WHERE Статус = 'активен'
      AND Дата_активации IS NOT NULL
      AND Дата_активации + (Срок_действия_дней || ' days')::INTERVAL < CURRENT_DATE
      AND Остаток_занятий > 0;  -- остались занятия, но срок истёк
    
    -- Если остаток = 0, статус уже 'закончился' (из триггера списания)
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public."обновить_статус_абонемента"() OWNER TO postgres;

--
-- TOC entry 249 (class 1255 OID 25148)
-- Name: проверка_реального_посещения(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."проверка_реального_посещения"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Проверяем, был ли клиент на этом занятии И отметка = 'посетил' или 'опоздал'
    IF NOT EXISTS (
        SELECT 1 FROM Посещения
        WHERE ID_клиента = NEW.ID_клиента
          AND ID_занятия = NEW.ID_занятия
          AND Отметка_тренера IN ('посетил', 'опоздал')
    ) THEN
        RAISE EXCEPTION 'Клиент не был на занятии, оставить отзыв нельзя';
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public."проверка_реального_посещения"() OWNER TO postgres;

--
-- TOC entry 251 (class 1255 OID 25165)
-- Name: списать_активный_абонемент(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."списать_активный_абонемент"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    активный_абонемент RECORD;
BEGIN
    IF NEW.Отметка_тренера NOT IN ('посетил', 'опоздал') THEN
        RETURN NEW;
    END IF;

    SELECT ка.*, а.Срок_действия_дней
    INTO активный_абонемент
    FROM Клиенты_Абонементы ка
    JOIN Абонементы а ON ка.ID_абонемента = а.ID_абонемента
    WHERE ка.ID_клиента = NEW.ID_клиента
      AND ка.Статус = 'активен'
      AND ка.Остаток_занятий > 0
      AND ка.Дата_активации IS NOT NULL
      AND (ка.Дата_активации + (а.Срок_действия_дней || ' days')::INTERVAL) >= CURRENT_DATE
    ORDER BY ка.Дата_покупки DESC
    LIMIT 1;

    IF FOUND THEN
        UPDATE Клиенты_Абонементы
        SET Остаток_занятий = Остаток_занятий - 1,
            Статус = CASE WHEN Остаток_занятий - 1 = 0 THEN 'закончился' ELSE Статус END
        WHERE ID_клиента = активный_абонемент.ID_клиента
          AND ID_абонемента = активный_абонемент.ID_абонемента
          AND Дата_покупки = активный_абонемент.Дата_покупки;
    ELSE
        RAISE EXCEPTION 'Клиент % не имеет активного абонемента с остатком занятий или срок действия истёк', NEW.ID_клиента;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public."списать_активный_абонемент"() OWNER TO postgres;

--
-- TOC entry 248 (class 1255 OID 25145)
-- Name: управление_статусами_абонементов(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public."управление_статусами_абонементов"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- ========================================
    -- ЧАСТЬ 1: Деактивируем старые абонементы клиента (если это INSERT)
    -- ========================================
    IF TG_OP = 'INSERT' THEN
        UPDATE Клиенты_Абонементы
        SET Статус = 
            CASE 
                WHEN Остаток_занятий = 0 THEN 'закончился'
                ELSE 'просрочен'
            END
        WHERE ID_клиента = NEW.ID_клиента
          AND Статус IN ('активен', 'неактивен')
          AND (ID_абонемента != NEW.ID_абонемента 
               OR (ID_абонемента = NEW.ID_абонемента AND Дата_покупки != NEW.Дата_покупки));
    END IF;
    
    -- ========================================
    -- ЧАСТЬ 2: Определяем статус ДЛЯ ТЕКУЩЕГО абонемента
    -- ========================================
    -- Правило 1: Если остаток = 0 → закончился
    IF NEW.Остаток_занятий = 0 THEN
        NEW.Статус := 'закончился';
    
    -- Правило 2: Если не активирован → неактивен
    ELSIF NEW.Дата_активации IS NULL THEN
        NEW.Статус := 'неактивен';
    
    -- Правило 3: Если остаток > 0 и активирован → проверяем срок
    ELSIF NEW.Остаток_занятий > 0 AND NEW.Дата_активации IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM Абонементы a
            WHERE a.ID_абонемента = NEW.ID_абонемента
              AND (NEW.Дата_активации + (a.Срок_действия_дней || ' days')::INTERVAL) < CURRENT_DATE
        ) THEN
            NEW.Статус := 'просрочен';
        ELSE
            NEW.Статус := 'активен';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION public."управление_статусами_абонементов"() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 222 (class 1259 OID 24969)
-- Name: Абонементы; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Абонементы" (
    "id_абонемента" integer NOT NULL,
    "Название" character varying(100) NOT NULL,
    "Количество_занятий" integer NOT NULL,
    "Цена" numeric(10,2) NOT NULL,
    "Срок_действия_дней" integer DEFAULT 30,
    CONSTRAINT "Абонементы_Количество_занятий_check" CHECK (("Количество_занятий" > 0)),
    CONSTRAINT "Абонементы_Цена_check" CHECK (("Цена" >= (0)::numeric))
);


ALTER TABLE public."Абонементы" OWNER TO postgres;

--
-- TOC entry 221 (class 1259 OID 24968)
-- Name: Абонементы_id_абонемента_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Абонементы_id_абонемента_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Абонементы_id_абонемента_seq" OWNER TO postgres;

--
-- TOC entry 5013 (class 0 OID 0)
-- Dependencies: 221
-- Name: Абонементы_id_абонемента_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Абонементы_id_абонемента_seq" OWNED BY public."Абонементы"."id_абонемента";


--
-- TOC entry 233 (class 1259 OID 25073)
-- Name: Администраторы; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Администраторы" (
    "id_администратора" integer NOT NULL,
    "Фамилия" character varying(50) NOT NULL,
    "Имя" character varying(50) NOT NULL,
    "Телефон" character varying(20),
    "Дата_трудоустройства" date DEFAULT CURRENT_DATE
);


ALTER TABLE public."Администраторы" OWNER TO postgres;

--
-- TOC entry 232 (class 1259 OID 25072)
-- Name: Администраторы_id_администратор_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Администраторы_id_администратор_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Администраторы_id_администратор_seq" OWNER TO postgres;

--
-- TOC entry 5014 (class 0 OID 0)
-- Dependencies: 232
-- Name: Администраторы_id_администратор_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Администраторы_id_администратор_seq" OWNED BY public."Администраторы"."id_администратора";


--
-- TOC entry 226 (class 1259 OID 24986)
-- Name: Групповые_занятия; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Групповые_занятия" (
    "id_занятия" integer NOT NULL,
    "Название" character varying(100) NOT NULL,
    "id_тренера" integer NOT NULL,
    "День_недели" character varying(10) NOT NULL,
    "Время" time without time zone NOT NULL,
    "Максимум_участников" integer DEFAULT 15
);


ALTER TABLE public."Групповые_занятия" OWNER TO postgres;

--
-- TOC entry 225 (class 1259 OID 24985)
-- Name: Групповые_занятия_id_занятия_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Групповые_занятия_id_занятия_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Групповые_занятия_id_занятия_seq" OWNER TO postgres;

--
-- TOC entry 5015 (class 0 OID 0)
-- Dependencies: 225
-- Name: Групповые_занятия_id_занятия_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Групповые_занятия_id_занятия_seq" OWNED BY public."Групповые_занятия"."id_занятия";


--
-- TOC entry 220 (class 1259 OID 24959)
-- Name: Клиенты; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Клиенты" (
    "id_клиента" integer NOT NULL,
    "Фамилия" character varying(50) NOT NULL,
    "Имя" character varying(50) NOT NULL,
    "Телефон" character varying(20),
    "Дата_регистрации" date DEFAULT CURRENT_DATE
);


ALTER TABLE public."Клиенты" OWNER TO postgres;

--
-- TOC entry 219 (class 1259 OID 24958)
-- Name: Клиенты_id_клиента_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Клиенты_id_клиента_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Клиенты_id_клиента_seq" OWNER TO postgres;

--
-- TOC entry 5016 (class 0 OID 0)
-- Dependencies: 219
-- Name: Клиенты_id_клиента_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Клиенты_id_клиента_seq" OWNED BY public."Клиенты"."id_клиента";


--
-- TOC entry 234 (class 1259 OID 25101)
-- Name: Клиенты_Абонементы; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Клиенты_Абонементы" (
    "id_клиента" integer NOT NULL,
    "id_абонемента" integer NOT NULL,
    "id_администратора" integer NOT NULL,
    "Дата_покупки" date DEFAULT CURRENT_DATE NOT NULL,
    "Дата_активации" date,
    "Статус" character varying(20) DEFAULT 'неактивен'::character varying,
    "Остаток_занятий" integer
);


ALTER TABLE public."Клиенты_Абонементы" OWNER TO postgres;

--
-- TOC entry 229 (class 1259 OID 25033)
-- Name: Оборудование; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Оборудование" (
    "id_оборудования" integer NOT NULL,
    "Название" character varying(100) NOT NULL,
    "Тип" character varying(50),
    "Дата_покупки" date,
    "Стоимость" numeric(10,2),
    "Статус" character varying(20) DEFAULT 'исправен'::character varying
);


ALTER TABLE public."Оборудование" OWNER TO postgres;

--
-- TOC entry 228 (class 1259 OID 25032)
-- Name: Оборудование_id_оборудования_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Оборудование_id_оборудования_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Оборудование_id_оборудования_seq" OWNER TO postgres;

--
-- TOC entry 5017 (class 0 OID 0)
-- Dependencies: 228
-- Name: Оборудование_id_оборудования_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Оборудование_id_оборудования_seq" OWNED BY public."Оборудование"."id_оборудования";


--
-- TOC entry 231 (class 1259 OID 25053)
-- Name: Отзывы_клиентов; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Отзывы_клиентов" (
    "id_клиента" integer NOT NULL,
    "id_занятия" integer NOT NULL,
    "Дата_отзыва" date DEFAULT CURRENT_DATE NOT NULL,
    "Оценка" integer NOT NULL,
    "Текст_отзыва" text,
    CONSTRAINT "Отзывы_клиентов_Оценка_check" CHECK ((("Оценка" >= 1) AND ("Оценка" <= 5)))
);


ALTER TABLE public."Отзывы_клиентов" OWNER TO postgres;

--
-- TOC entry 227 (class 1259 OID 25015)
-- Name: Посещения; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Посещения" (
    "id_клиента" integer NOT NULL,
    "id_занятия" integer NOT NULL,
    "Дата_посещения" date DEFAULT CURRENT_DATE NOT NULL,
    "Отметка_тренера" character varying(20) DEFAULT 'посетил'::character varying
);


ALTER TABLE public."Посещения" OWNER TO postgres;

--
-- TOC entry 230 (class 1259 OID 25040)
-- Name: Ремонт_оборудования; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Ремонт_оборудования" (
    "id_оборудования" integer NOT NULL,
    "Дата_поломки" date DEFAULT CURRENT_DATE NOT NULL,
    "Дата_ремонта" date,
    "Стоимость_ремонта" numeric(10,2),
    "Примечание" text
);


ALTER TABLE public."Ремонт_оборудования" OWNER TO postgres;

--
-- TOC entry 224 (class 1259 OID 24979)
-- Name: Тренеры; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."Тренеры" (
    "id_тренера" integer NOT NULL,
    "Фамилия" character varying(50) NOT NULL,
    "Имя" character varying(50) NOT NULL,
    "Специализация" character varying(100),
    "Телефон" character varying(20),
    "Ставка_за_занятие" numeric(10,2)
);


ALTER TABLE public."Тренеры" OWNER TO postgres;

--
-- TOC entry 223 (class 1259 OID 24978)
-- Name: Тренеры_id_тренера_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public."Тренеры_id_тренера_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public."Тренеры_id_тренера_seq" OWNER TO postgres;

--
-- TOC entry 5018 (class 0 OID 0)
-- Dependencies: 223
-- Name: Тренеры_id_тренера_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public."Тренеры_id_тренера_seq" OWNED BY public."Тренеры"."id_тренера";


--
-- TOC entry 4793 (class 2604 OID 24972)
-- Name: Абонементы id_абонемента; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Абонементы" ALTER COLUMN "id_абонемента" SET DEFAULT nextval('public."Абонементы_id_абонемента_seq"'::regclass);


--
-- TOC entry 4804 (class 2604 OID 25076)
-- Name: Администраторы id_администратора; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Администраторы" ALTER COLUMN "id_администратора" SET DEFAULT nextval('public."Администраторы_id_администратор_seq"'::regclass);


--
-- TOC entry 4796 (class 2604 OID 24989)
-- Name: Групповые_занятия id_занятия; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Групповые_занятия" ALTER COLUMN "id_занятия" SET DEFAULT nextval('public."Групповые_занятия_id_занятия_seq"'::regclass);


--
-- TOC entry 4791 (class 2604 OID 24962)
-- Name: Клиенты id_клиента; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты" ALTER COLUMN "id_клиента" SET DEFAULT nextval('public."Клиенты_id_клиента_seq"'::regclass);


--
-- TOC entry 4800 (class 2604 OID 25036)
-- Name: Оборудование id_оборудования; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Оборудование" ALTER COLUMN "id_оборудования" SET DEFAULT nextval('public."Оборудование_id_оборудования_seq"'::regclass);


--
-- TOC entry 4795 (class 2604 OID 24982)
-- Name: Тренеры id_тренера; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Тренеры" ALTER COLUMN "id_тренера" SET DEFAULT nextval('public."Тренеры_id_тренера_seq"'::regclass);


--
-- TOC entry 4994 (class 0 OID 24969)
-- Dependencies: 222
-- Data for Name: Абонементы; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Абонементы" ("id_абонемента", "Название", "Количество_занятий", "Цена", "Срок_действия_дней") FROM stdin;
1	Стандарт	8	3200.00	30
2	VIP	20	7000.00	60
3	Утренний	12	4000.00	45
4	Пробный	1	0.00	7
5	Безлимит	99	12000.00	90
\.


--
-- TOC entry 5005 (class 0 OID 25073)
-- Dependencies: 233
-- Data for Name: Администраторы; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Администраторы" ("id_администратора", "Фамилия", "Имя", "Телефон", "Дата_трудоустройства") FROM stdin;
1	Соколова	Анна	+7-931-111-11-11	2025-06-01
2	Морозов	Денис	+7-932-222-22-22	2025-07-15
3	Белова	Екатерина	+7-933-333-33-33	2025-08-20
4	Григорьев	Павел	+7-934-444-44-44	2026-01-10
\.


--
-- TOC entry 4998 (class 0 OID 24986)
-- Dependencies: 226
-- Data for Name: Групповые_занятия; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Групповые_занятия" ("id_занятия", "Название", "id_тренера", "День_недели", "Время", "Максимум_участников") FROM stdin;
1	Силовой тренинг	1	ПН	18:00:00	12
2	Йога	2	ВТ	10:00:00	15
3	Бокс	3	СР	19:00:00	10
4	Пилатес	4	ЧТ	09:00:00	15
5	Кроссфит	5	ПТ	18:00:00	12
6	Йога	2	СБ	11:00:00	15
7	Силовой тренинг	1	СР	19:00:00	12
\.


--
-- TOC entry 4992 (class 0 OID 24959)
-- Dependencies: 220
-- Data for Name: Клиенты; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Клиенты" ("id_клиента", "Фамилия", "Имя", "Телефон", "Дата_регистрации") FROM stdin;
1	Иванова	Анна	+7-901-111-22-33	2026-01-10
2	Петров	Сергей	+7-902-222-33-44	2026-01-12
3	Сидорова	Мария	+7-903-333-44-55	2026-01-15
4	Козлов	Дмитрий	+7-904-444-55-66	2026-01-18
5	Новикова	Елена	+7-905-555-66-77	2026-01-20
6	Морозов	Андрей	+7-906-666-77-88	2026-02-01
7	Волкова	Татьяна	+7-907-777-88-99	2026-02-05
8	Соколов	Иван	+7-908-888-99-00	2026-02-10
9	Лебедева	Ольга	+7-909-999-00-11	2026-02-15
10	Павлов	Михаил	+7-910-000-11-22	2026-03-01
11	Егорова	Наталья	+7-911-111-22-33	2026-03-05
12	Тимофеев	Алексей	+7-912-222-33-44	2026-03-10
\.


--
-- TOC entry 5006 (class 0 OID 25101)
-- Dependencies: 234
-- Data for Name: Клиенты_Абонементы; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Клиенты_Абонементы" ("id_клиента", "id_абонемента", "id_администратора", "Дата_покупки", "Дата_активации", "Статус", "Остаток_занятий") FROM stdin;
3	1	2	2026-05-10	2026-05-11	активен	7
9	5	4	2026-03-15	\N	неактивен	99
11	5	4	2026-04-25	\N	неактивен	99
1	1	1	2026-01-20	2026-01-22	просрочен	5
2	2	1	2026-01-15	2026-01-18	просрочен	15
3	3	2	2026-02-10	2026-02-12	просрочен	9
4	1	2	2026-02-05	2026-02-08	просрочен	6
5	4	3	2026-03-01	2026-03-02	закончился	0
6	1	3	2026-02-10	2026-02-12	просрочен	6
7	3	1	2026-02-20	2026-02-22	просрочен	10
8	2	2	2026-03-01	2026-03-03	просрочен	18
10	4	4	2026-03-20	2026-03-21	закончился	0
12	1	1	2026-05-05	2026-05-06	активен	7
\.


--
-- TOC entry 5001 (class 0 OID 25033)
-- Dependencies: 229
-- Data for Name: Оборудование; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Оборудование" ("id_оборудования", "Название", "Тип", "Дата_покупки", "Стоимость", "Статус") FROM stdin;
1	Беговая дорожка ProForm	Кардио	2023-01-15	150000.00	исправен
2	Велотренажер Spirit	Кардио	2023-02-10	120000.00	исправен
3	Штанга олимпийская	Силовой	2022-11-20	25000.00	исправен
4	Гантельный ряд 5-50 кг	Силовой	2022-12-01	180000.00	исправен
5	Скамья для жима	Силовой	2023-01-05	45000.00	в ремонте
6	Тренажер для пресса	Силовой	2023-03-10	35000.00	исправен
7	Эллиптический тренажер	Кардио	2023-04-15	110000.00	исправен
8	Степпер	Кардио	2023-05-20	55000.00	исправен
9	Турник	Силовой	2023-06-01	15000.00	исправен
10	Массажный валик	Инвентарь	2024-01-10	3000.00	исправен
\.


--
-- TOC entry 5003 (class 0 OID 25053)
-- Dependencies: 231
-- Data for Name: Отзывы_клиентов; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Отзывы_клиентов" ("id_клиента", "id_занятия", "Дата_отзыва", "Оценка", "Текст_отзыва") FROM stdin;
1	1	2026-01-23	5	Отличная тренировка!
2	3	2026-01-20	4	Хорошо, но интенсивно
3	2	2026-02-13	5	Йога — любовь
4	4	2026-02-09	4	Пилатес помогает спине
5	2	2026-03-03	3	Норм, но не моё
6	1	2026-02-13	5	Силовой топ!
7	3	2026-02-23	5	Бокс бомба
8	5	2026-03-05	4	Кроссфит эффективный
10	4	2026-03-22	4	Хорошо для начинающих
12	1	2026-04-11	5	Первый раз — супер
\.


--
-- TOC entry 4999 (class 0 OID 25015)
-- Dependencies: 227
-- Data for Name: Посещения; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Посещения" ("id_клиента", "id_занятия", "Дата_посещения", "Отметка_тренера") FROM stdin;
3	1	2026-05-11	посетил
1	1	2026-01-22	посетил
1	5	2026-01-25	посетил
1	7	2026-01-28	опоздал
2	3	2026-01-18	посетил
2	3	2026-01-22	посетил
2	3	2026-01-25	посетил
2	3	2026-01-28	опоздал
2	3	2026-02-01	посетил
3	2	2026-02-12	посетил
3	6	2026-02-15	посетил
3	2	2026-02-18	опоздал
4	4	2026-02-08	посетил
4	1	2026-02-12	посетил
5	2	2026-03-02	посетил
6	1	2026-02-12	посетил
6	5	2026-02-15	посетил
7	3	2026-02-22	посетил
7	3	2026-02-25	посетил
8	5	2026-03-03	посетил
8	5	2026-03-06	опоздал
10	4	2026-03-21	посетил
12	1	2026-05-06	посетил
\.


--
-- TOC entry 5002 (class 0 OID 25040)
-- Dependencies: 230
-- Data for Name: Ремонт_оборудования; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Ремонт_оборудования" ("id_оборудования", "Дата_поломки", "Дата_ремонта", "Стоимость_ремонта", "Примечание") FROM stdin;
5	2026-01-10	2026-01-20	8000.00	Замена обивки
3	2026-01-15	2026-01-18	3000.00	Замена грифа
1	2026-02-01	2026-02-10	15000.00	Замена двигателя
2	2026-02-15	2026-02-20	5000.00	Ремонт педального узла
5	2026-03-01	2026-03-10	6000.00	Повторная замена обивки
7	2026-03-15	2026-03-20	4000.00	Замена подшипников
\.


--
-- TOC entry 4996 (class 0 OID 24979)
-- Dependencies: 224
-- Data for Name: Тренеры; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."Тренеры" ("id_тренера", "Фамилия", "Имя", "Специализация", "Телефон", "Ставка_за_занятие") FROM stdin;
1	Смирнов	Алексей	Силовые тренировки	+7-921-111-11-11	1500.00
2	Кузнецова	Ольга	Йога	+7-922-222-22-22	2000.00
3	Морозов	Иван	Бокс	+7-923-333-33-33	1800.00
4	Волкова	Екатерина	Пилатес	+7-924-444-44-44	1700.00
5	Федоров	Дмитрий	Кроссфит	+7-925-555-55-55	1900.00
\.


--
-- TOC entry 5019 (class 0 OID 0)
-- Dependencies: 221
-- Name: Абонементы_id_абонемента_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Абонементы_id_абонемента_seq"', 5, true);


--
-- TOC entry 5020 (class 0 OID 0)
-- Dependencies: 232
-- Name: Администраторы_id_администратор_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Администраторы_id_администратор_seq"', 4, true);


--
-- TOC entry 5021 (class 0 OID 0)
-- Dependencies: 225
-- Name: Групповые_занятия_id_занятия_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Групповые_занятия_id_занятия_seq"', 7, true);


--
-- TOC entry 5022 (class 0 OID 0)
-- Dependencies: 219
-- Name: Клиенты_id_клиента_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Клиенты_id_клиента_seq"', 12, true);


--
-- TOC entry 5023 (class 0 OID 0)
-- Dependencies: 228
-- Name: Оборудование_id_оборудования_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Оборудование_id_оборудования_seq"', 10, true);


--
-- TOC entry 5024 (class 0 OID 0)
-- Dependencies: 223
-- Name: Тренеры_id_тренера_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public."Тренеры_id_тренера_seq"', 5, true);


--
-- TOC entry 4816 (class 2606 OID 24977)
-- Name: Абонементы Абонементы_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Абонементы"
    ADD CONSTRAINT "Абонементы_pkey" PRIMARY KEY ("id_абонемента");


--
-- TOC entry 4830 (class 2606 OID 25079)
-- Name: Администраторы Администраторы_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Администраторы"
    ADD CONSTRAINT "Администраторы_pkey" PRIMARY KEY ("id_администратора");


--
-- TOC entry 4820 (class 2606 OID 24992)
-- Name: Групповые_занятия Групповые_занятия_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Групповые_занятия"
    ADD CONSTRAINT "Групповые_занятия_pkey" PRIMARY KEY ("id_занятия");


--
-- TOC entry 4812 (class 2606 OID 24965)
-- Name: Клиенты Клиенты_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты"
    ADD CONSTRAINT "Клиенты_pkey" PRIMARY KEY ("id_клиента");


--
-- TOC entry 4832 (class 2606 OID 25107)
-- Name: Клиенты_Абонементы Клиенты_Абонементы_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты_Абонементы"
    ADD CONSTRAINT "Клиенты_Абонементы_pkey" PRIMARY KEY ("id_клиента", "id_абонемента", "Дата_покупки");


--
-- TOC entry 4814 (class 2606 OID 24967)
-- Name: Клиенты Клиенты_Телефон_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты"
    ADD CONSTRAINT "Клиенты_Телефон_key" UNIQUE ("Телефон");


--
-- TOC entry 4824 (class 2606 OID 25039)
-- Name: Оборудование Оборудование_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Оборудование"
    ADD CONSTRAINT "Оборудование_pkey" PRIMARY KEY ("id_оборудования");


--
-- TOC entry 4828 (class 2606 OID 25061)
-- Name: Отзывы_клиентов Отзывы_клиентов_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Отзывы_клиентов"
    ADD CONSTRAINT "Отзывы_клиентов_pkey" PRIMARY KEY ("id_клиента", "id_занятия", "Дата_отзыва");


--
-- TOC entry 4822 (class 2606 OID 25021)
-- Name: Посещения Посещения_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Посещения"
    ADD CONSTRAINT "Посещения_pkey" PRIMARY KEY ("id_клиента", "id_занятия", "Дата_посещения");


--
-- TOC entry 4826 (class 2606 OID 25047)
-- Name: Ремонт_оборудования Ремонт_оборудования_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Ремонт_оборудования"
    ADD CONSTRAINT "Ремонт_оборудования_pkey" PRIMARY KEY ("id_оборудования", "Дата_поломки");


--
-- TOC entry 4818 (class 2606 OID 24984)
-- Name: Тренеры Тренеры_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Тренеры"
    ADD CONSTRAINT "Тренеры_pkey" PRIMARY KEY ("id_тренера");


--
-- TOC entry 4842 (class 2620 OID 25164)
-- Name: Посещения триггер_автоактивация; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "триггер_автоактивация" BEFORE INSERT ON public."Посещения" FOR EACH ROW EXECUTE FUNCTION public."автоактивация_абонемента"();


--
-- TOC entry 4844 (class 2620 OID 25149)
-- Name: Отзывы_клиентов триггер_проверка_отзыва; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "триггер_проверка_отзыва" BEFORE INSERT ON public."Отзывы_клиентов" FOR EACH ROW EXECUTE FUNCTION public."проверка_реального_посещения"();


--
-- TOC entry 4843 (class 2620 OID 25166)
-- Name: Посещения триггер_списание_занятий; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "триггер_списание_занятий" BEFORE INSERT ON public."Посещения" FOR EACH ROW EXECUTE FUNCTION public."списать_активный_абонемент"();


--
-- TOC entry 4845 (class 2620 OID 25146)
-- Name: Клиенты_Абонементы триггер_управление_статусами; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "триггер_управление_статусами" BEFORE INSERT OR UPDATE OF "Остаток_занятий", "Дата_активации" ON public."Клиенты_Абонементы" FOR EACH ROW EXECUTE FUNCTION public."управление_статусами_абонементов"();


--
-- TOC entry 4833 (class 2606 OID 24993)
-- Name: Групповые_занятия Групповые_занятия_id_тренера_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Групповые_занятия"
    ADD CONSTRAINT "Групповые_занятия_id_тренера_fkey" FOREIGN KEY ("id_тренера") REFERENCES public."Тренеры"("id_тренера");


--
-- TOC entry 4839 (class 2606 OID 25118)
-- Name: Клиенты_Абонементы Клиенты_Абонеме_id_администрато_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты_Абонементы"
    ADD CONSTRAINT "Клиенты_Абонеме_id_администрато_fkey" FOREIGN KEY ("id_администратора") REFERENCES public."Администраторы"("id_администратора");


--
-- TOC entry 4840 (class 2606 OID 25113)
-- Name: Клиенты_Абонементы Клиенты_Абонемент_id_абонемента_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты_Абонементы"
    ADD CONSTRAINT "Клиенты_Абонемент_id_абонемента_fkey" FOREIGN KEY ("id_абонемента") REFERENCES public."Абонементы"("id_абонемента");


--
-- TOC entry 4841 (class 2606 OID 25108)
-- Name: Клиенты_Абонементы Клиенты_Абонементы_id_клиента_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Клиенты_Абонементы"
    ADD CONSTRAINT "Клиенты_Абонементы_id_клиента_fkey" FOREIGN KEY ("id_клиента") REFERENCES public."Клиенты"("id_клиента");


--
-- TOC entry 4837 (class 2606 OID 25067)
-- Name: Отзывы_клиентов Отзывы_клиентов_id_занятия_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Отзывы_клиентов"
    ADD CONSTRAINT "Отзывы_клиентов_id_занятия_fkey" FOREIGN KEY ("id_занятия") REFERENCES public."Групповые_занятия"("id_занятия");


--
-- TOC entry 4838 (class 2606 OID 25062)
-- Name: Отзывы_клиентов Отзывы_клиентов_id_клиента_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Отзывы_клиентов"
    ADD CONSTRAINT "Отзывы_клиентов_id_клиента_fkey" FOREIGN KEY ("id_клиента") REFERENCES public."Клиенты"("id_клиента");


--
-- TOC entry 4834 (class 2606 OID 25027)
-- Name: Посещения Посещения_id_занятия_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Посещения"
    ADD CONSTRAINT "Посещения_id_занятия_fkey" FOREIGN KEY ("id_занятия") REFERENCES public."Групповые_занятия"("id_занятия");


--
-- TOC entry 4835 (class 2606 OID 25022)
-- Name: Посещения Посещения_id_клиента_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Посещения"
    ADD CONSTRAINT "Посещения_id_клиента_fkey" FOREIGN KEY ("id_клиента") REFERENCES public."Клиенты"("id_клиента");


--
-- TOC entry 4836 (class 2606 OID 25048)
-- Name: Ремонт_оборудования Ремонт_оборудов_id_оборудования_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."Ремонт_оборудования"
    ADD CONSTRAINT "Ремонт_оборудов_id_оборудования_fkey" FOREIGN KEY ("id_оборудования") REFERENCES public."Оборудование"("id_оборудования");


-- Completed on 2026-05-12 15:23:42

--
-- PostgreSQL database dump complete
--

\unrestrict ucXKl24geYk69xz9KfR8TWHHlv4jzKDMvukeTboWBMKbNMKFtZTKMX4oYFxpBux

