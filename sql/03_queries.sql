-- Examples adapted to the supplied PostgreSQL schema during portfolio preparation.
SET search_path = public;

-- 1. Membership purchases by type. The amount uses the current catalogue price,
-- not a historical payment ledger: sale prices are not stored separately.
SELECT a."Название", count(*) AS "Количество_покупок",
       sum(a."Цена") AS "Сумма_по_цене_каталога"
FROM "Клиенты_Абонементы" k
JOIN "Абонементы" a USING ("id_абонемента")
GROUP BY a."id_абонемента", a."Название"
ORDER BY "Сумма_по_цене_каталога" DESC;

-- 2. Actual attendance per class AND date; no-shows do not count.
-- Only dates present in the attendance table are shown; this is not a full calendar.
SELECT g."Название", p."Дата_посещения",
       count(*) FILTER (WHERE p."Отметка_тренера" IN ('посетил', 'опоздал')) AS "Посетителей",
       round(100.0 * count(*) FILTER (WHERE p."Отметка_тренера" IN ('посетил', 'опоздал'))
             / nullif(g."Максимум_участников", 0), 1) AS "Заполняемость_процентов"
FROM "Посещения" p
JOIN "Групповые_занятия" g USING ("id_занятия")
GROUP BY g."id_занятия", g."Название", g."Максимум_участников", p."Дата_посещения"
ORDER BY p."Дата_посещения", g."id_занятия";

-- 3. Repair expenses per piece of equipment, including equipment without repairs.
SELECT o."Название", count(r."Дата_поломки") AS "Количество_ремонтов",
       coalesce(sum(r."Стоимость_ремонта"), 0) AS "Затраты"
FROM "Оборудование" o
LEFT JOIN "Ремонт_оборудования" r USING ("id_оборудования")
GROUP BY o."id_оборудования", o."Название"
ORDER BY "Затраты" DESC;
