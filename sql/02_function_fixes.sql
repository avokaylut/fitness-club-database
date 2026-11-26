-- Corrections added during portfolio preparation; original definitions remain in 01.

CREATE OR REPLACE FUNCTION public."автоактивация_абонемента"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

DECLARE
    активный_неактивированный RECORD;
BEGIN
    IF NEW."Отметка_тренера" IS NULL OR NEW."Отметка_тренера" NOT IN ('посетил', 'опоздал') THEN
        RETURN NEW;
    END IF;
    -- Ищем неактивированный абонемент клиента
    SELECT ка.* INTO активный_неактивированный
    FROM "Клиенты_Абонементы" ка
    WHERE ка."id_клиента" = NEW."id_клиента"
      AND ка."Дата_активации" IS NULL
    ORDER BY ка."Дата_покупки" ASC
    LIMIT 1;
    
    -- Если нашли — активируем
    IF FOUND THEN
        UPDATE "Клиенты_Абонементы"
        SET "Дата_активации" = NEW."Дата_посещения",
            "Статус" = 'активен'
        WHERE "id_клиента" = активный_неактивированный."id_клиента"
          AND "id_абонемента" = активный_неактивированный."id_абонемента"
          AND "Дата_покупки" = активный_неактивированный."Дата_покупки";
    END IF;
    
    RETURN NEW;
END;

$$;

CREATE OR REPLACE FUNCTION public."деактивировать_старые_абонементы"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

BEGIN
    -- Деактивируем все другие абонементы этого клиента
    UPDATE "Клиенты_Абонементы"
    SET "Статус" = 
        CASE 
            WHEN "Остаток_занятий" = 0 THEN 'закончился'
            ELSE 'просрочен'
        END
    WHERE "id_клиента" = NEW."id_клиента"
      AND "Статус" IN ('активен', 'неактивен')
      AND ("id_абонемента" != NEW."id_абонемента" 
           OR ("id_абонемента" = NEW."id_абонемента" AND "Дата_покупки" != NEW."Дата_покупки"));
    
    RETURN NEW;
END;

$$;

CREATE OR REPLACE FUNCTION public."обновить_статус_абонемента"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

BEGIN
    -- Для активных абонементов проверяем срок действия
    UPDATE "Клиенты_Абонементы" AS ка
    SET "Статус" = 'просрочен'
    FROM "Абонементы" AS а
    WHERE ка."id_абонемента" = а."id_абонемента" AND "Статус" = 'активен'
      AND "Дата_активации" IS NOT NULL
      AND "Дата_активации" + (а."Срок_действия_дней" || ' days')::INTERVAL < CURRENT_DATE
      AND "Остаток_занятий" > 0;  -- остались занятия, но срок истёк
    
    -- Если остаток = 0, статус уже 'закончился' (из триггера списания)
    
    RETURN NEW;
END;

$$;

CREATE OR REPLACE FUNCTION public."проверка_реального_посещения"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

BEGIN
    -- Проверяем, был ли клиент на этом занятии И отметка = 'посетил' или 'опоздал'
    IF NOT EXISTS (
        SELECT 1 FROM "Посещения"
        WHERE "id_клиента" = NEW."id_клиента"
          AND "id_занятия" = NEW."id_занятия"
          AND "Отметка_тренера" IN ('посетил', 'опоздал')
    ) THEN
        RAISE EXCEPTION 'Клиент не был на занятии, оставить отзыв нельзя';
    END IF;
    
    RETURN NEW;
END;

$$;

CREATE OR REPLACE FUNCTION public."списать_активный_абонемент"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

DECLARE
    активный_абонемент RECORD;
BEGIN
    IF NEW."Отметка_тренера" NOT IN ('посетил', 'опоздал') THEN
        RETURN NEW;
    END IF;

    SELECT ка.*, а."Срок_действия_дней"
    INTO активный_абонемент
    FROM "Клиенты_Абонементы" ка
    JOIN "Абонементы" а ON ка."id_абонемента" = а."id_абонемента"
    WHERE ка."id_клиента" = NEW."id_клиента"
      AND ка."Статус" = 'активен'
      AND ка."Остаток_занятий" > 0
      AND ка."Дата_активации" IS NOT NULL
      AND (ка."Дата_активации" + (а."Срок_действия_дней" || ' days')::INTERVAL) >= CURRENT_DATE
    ORDER BY ка."Дата_покупки" DESC
    LIMIT 1;

    IF FOUND THEN
        UPDATE "Клиенты_Абонементы"
        SET "Остаток_занятий" = "Остаток_занятий" - 1,
            "Статус" = CASE WHEN "Остаток_занятий" - 1 = 0 THEN 'закончился' ELSE "Статус" END
        WHERE "id_клиента" = активный_абонемент."id_клиента"
          AND "id_абонемента" = активный_абонемент."id_абонемента"
          AND "Дата_покупки" = активный_абонемент."Дата_покупки";
    ELSE
        RAISE EXCEPTION 'Клиент % не имеет активного абонемента с остатком занятий или срок действия истёк', NEW."id_клиента";
    END IF;

    RETURN NEW;
END;

$$;

CREATE OR REPLACE FUNCTION public."управление_статусами_абонементов"() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$

BEGIN
    -- ========================================
    -- ЧАСТЬ 1: Деактивируем старые абонементы клиента (если это INSERT)
    -- ========================================
    IF TG_OP = 'INSERT' THEN
        UPDATE "Клиенты_Абонементы"
        SET "Статус" = 
            CASE 
                WHEN "Остаток_занятий" = 0 THEN 'закончился'
                ELSE 'просрочен'
            END
        WHERE "id_клиента" = NEW."id_клиента"
          AND "Статус" IN ('активен', 'неактивен')
          AND ("id_абонемента" != NEW."id_абонемента" 
               OR ("id_абонемента" = NEW."id_абонемента" AND "Дата_покупки" != NEW."Дата_покупки"));
    END IF;
    
    -- ========================================
    -- ЧАСТЬ 2: Определяем статус ДЛЯ ТЕКУЩЕГО абонемента
    -- ========================================
    -- Правило 1: Если остаток = 0 → закончился
    IF NEW."Остаток_занятий" = 0 THEN
        NEW."Статус" := 'закончился';
    
    -- Правило 2: Если не активирован → неактивен
    ELSIF NEW."Дата_активации" IS NULL THEN
        NEW."Статус" := 'неактивен';
    
    -- Правило 3: Если остаток > 0 и активирован → проверяем срок
    ELSIF NEW."Остаток_занятий" > 0 AND NEW."Дата_активации" IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM "Абонементы" a
            WHERE a."id_абонемента" = NEW."id_абонемента"
              AND (NEW."Дата_активации" + (a."Срок_действия_дней" || ' days')::INTERVAL) < CURRENT_DATE
        ) THEN
            NEW."Статус" := 'просрочен';
        ELSE
            NEW."Статус" := 'активен';
        END IF;
    END IF;
    
    RETURN NEW;
END;

$$;
