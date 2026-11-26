\set ON_ERROR_STOP on
-- Run only on a disposable database restored from sql/01_restore.sql + 02_function_fixes.sql.
-- All fixture mutations are rolled back; explicit negative IDs avoid consuming sequences.
BEGIN;
SET search_path = public;
DO $$
DECLARE n integer; balance integer; message text;
BEGIN
    SELECT count(*) INTO n FROM pg_tables WHERE schemaname = 'public';
    ASSERT n = 10, 'Expected 10 original tables';
    SELECT count(*) INTO n FROM pg_trigger WHERE NOT tgisinternal;
    ASSERT n = 4, 'Expected 4 original triggers';
    ASSERT (SELECT count(*) FROM "Клиенты") = 12, 'Expected 12 fixture clients';
    ASSERT (SELECT count(*) FROM "Посещения") = 23, 'Expected 23 fixture visits';
    RAISE NOTICE 'PASS: restored structure and data';

    INSERT INTO "Клиенты" ("id_клиента", "Фамилия", "Имя") VALUES (-1001, 'Тест', 'Проверка');
    INSERT INTO "Клиенты_Абонементы"
      ("id_клиента", "id_абонемента", "id_администратора", "Дата_покупки", "Остаток_занятий")
      VALUES (-1001, 1, 1, CURRENT_DATE, 8);
    ASSERT (SELECT "Статус" = 'неактивен' FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001);
    RAISE NOTICE 'PASS: purchase without activation';

    INSERT INTO "Посещения" VALUES (-1001, 2, CURRENT_DATE, 'не пришел');
    ASSERT (SELECT "Дата_активации" IS NULL AND "Остаток_занятий" = 8
            FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001);
    RAISE NOTICE 'PASS: no-show does not activate or consume membership';

    INSERT INTO "Посещения" VALUES (-1001, 1, CURRENT_DATE, 'посетил');
    ASSERT (SELECT "Дата_активации" = CURRENT_DATE AND "Остаток_занятий" = 7 AND "Статус" = 'активен'
            FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001);
    RAISE NOTICE 'PASS: first attendance activates and consumes one session';

    INSERT INTO "Посещения" VALUES (-1001, 3, CURRENT_DATE, 'опоздал');
    ASSERT (SELECT "Остаток_занятий" = 6 FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001);
    RAISE NOTICE 'PASS: late attendance consumes one session';

    BEGIN
        INSERT INTO "Посещения" VALUES (-1001, 1, CURRENT_DATE, 'посетил');
        RAISE EXCEPTION 'Duplicate visit unexpectedly accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    ASSERT (SELECT "Остаток_занятий" = 6 FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001);
    RAISE NOTICE 'PASS: duplicate visit rolls back consumption';

    INSERT INTO "Отзывы_клиентов" VALUES (-1001, 1, CURRENT_DATE, 5, 'Тестовый отзыв');
    BEGIN
        INSERT INTO "Отзывы_клиентов" VALUES (-1001, 2, CURRENT_DATE, 5, 'Неявка');
        RAISE EXCEPTION 'Review without attendance unexpectedly accepted';
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message = 'Клиент не был на занятии, оставить отзыв нельзя', message;
    END;
    RAISE NOTICE 'PASS: review requires actual attendance';
    BEGIN
        INSERT INTO "Отзывы_клиентов" VALUES (-1001, 3, CURRENT_DATE, 9, 'Неверная оценка');
        RAISE EXCEPTION 'Invalid rating unexpectedly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS: rating outside 1-5 rejected';

    INSERT INTO "Клиенты_Абонементы"
      ("id_клиента", "id_абонемента", "id_администратора", "Дата_покупки", "Остаток_занятий")
      VALUES (-1001, 4, 1, CURRENT_DATE, 1);
    ASSERT (SELECT "Статус" = 'просрочен' FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001 AND "id_абонемента" = 1);
    INSERT INTO "Посещения" VALUES (-1001, 4, CURRENT_DATE, 'посетил');
    ASSERT (SELECT "Остаток_занятий" = 0 AND "Статус" = 'закончился'
            FROM "Клиенты_Абонементы" WHERE "id_клиента" = -1001 AND "id_абонемента" = 4);
    RAISE NOTICE 'PASS: replacement deactivates old membership; last session exhausts new membership';
    BEGIN
        INSERT INTO "Посещения" VALUES (-1001, 5, CURRENT_DATE, 'посетил');
        RAISE EXCEPTION 'Attendance without balance unexpectedly accepted';
    EXCEPTION WHEN raise_exception THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message LIKE 'Клиент -1001 не имеет активного абонемента%', message;
    END;
    RAISE NOTICE 'PASS: attendance without eligible membership rejected';

    BEGIN
        INSERT INTO "Клиенты_Абонементы"
          ("id_клиента", "id_абонемента", "id_администратора", "Дата_покупки", "Остаток_занятий")
          VALUES (-9999, 1, 1, CURRENT_DATE, 8);
        RAISE EXCEPTION 'Invalid foreign key unexpectedly accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS: foreign key enforced';
END;
$$;
ROLLBACK;
