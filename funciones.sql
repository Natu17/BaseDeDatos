CREATE TABLE intermedia
(
    quarter       TEXT NOT NULL CHECK (quarter SIMILAR TO 'Q(1|2|3|4)/%'),
    month         TEXT NOT NULL CHECK (SUBSTRING(month, 1, 2) = SUBSTRING(quarter, 6, 7)),
    week          TEXT NOT NULL CHECK (week SIMILAR TO 'W(1|2|3|4|5)-%' AND
                                       SUBSTRING(week, 4, 7) = SUBSTRING(quarter, 4, 7)),
    product_type  TEXT NOT NULL,
    territory     TEXT NOT NULL,
    sales_channel TEXT NOT NULL CHECK (sales_channel IN ('Direct', 'Internet', 'Retail')),
    customer_type TEXT NOT NULL,
    revenue       FLOAT CHECK (revenue >= 0),
    cost          FLOAT CHECK (cost >= 0),
    PRIMARY KEY (month, week, product_type, territory, sales_channel, customer_type)
);


CREATE TABLE definitiva
(
    sales_date    DATE not NULL,
    product_type  TEXT NOT NULL,
    territory     TEXT NOT NULL,
    sales_channel TEXT NOT NULL CHECK (sales_channel IN ('Direct', 'Internet', 'Retail')),
    customer_type TEXT NOT NULL,
    revenue       FLOAT CHECK (revenue >= 0),
    cost          FLOAT CHECK (cost >= 0),
    PRIMARY KEY (sales_date, product_type, territory, sales_channel, customer_type)
);



CREATE OR REPLACE FUNCTION toDate(
    quarter IN intermedia.quarter%type,
    week IN intermedia.week%type,
    month IN intermedia.month%type
) RETURNS DATE
AS
$$
DECLARE
    year_str  TEXT;
    month_str TEXT;
    day_str   TEXT;
BEGIN
    year_str := SUBSTRING(quarter, 4, 7);
    month_str := CAST(EXTRACT(MONTH FROM TO_DATE(SUBSTRING(month, 4, 6), 'Mon')) AS TEXT);
    month_str := LPAD(month_str, 2, '0');
    CASE (SUBSTRING(week, 1, 2))
        WHEN 'W1' then day_str := '01';
        WHEN 'W2' then day_str := '08';
        WHEN 'W3' then day_str := '15';
        WHEN 'W4' then day_str := '22';
        WHEN 'W5' then day_str := '29';
        END CASE;

    RETURN TO_DATE(year_str || month_str || day_str, 'YYYYMMDD');
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION intToDef() RETURNS trigger AS
$intToDef$
BEGIN
    INSERT INTO definitiva
    VALUES (toDate(new.quarter, new.week, new.month), new.product_type, new.territory, new.sales_channel,
            new.customer_type, new.revenue, new.cost);
    RETURN NEW;
END;
$intToDef$ LANGUAGE plpgsql;

CREATE TRIGGER intToDef
    BEFORE INSERT
    ON intermedia
    FOR EACH ROW
EXECUTE PROCEDURE intToDef();


CREATE OR REPLACE FUNCTION MedianaMargenMovil(
    date IN DATE,
    n IN INTEGER
) RETURNS NUMERIC
AS
$$
DECLARE
    ans             NUMERIC;
    limit_date      DATE;
    interval_months INTERVAL;
BEGIN
    IF (n <= 0) THEN
        raise notice 'La cantidad de meses anteriores debe ser mayor a 0';
        RETURN NULL;
    END IF;
    interval_months := make_interval(0, n, 0, 0, 0, 0, 0);
    limit_date := date - interval_months;
    SELECT percentile_cont(0.5) within group (order by revenue - cost)
    FROM definitiva
    WHERE sales_date <= date
      AND sales_date > limit_date
    INTO ans;

    RETURN ROUND(ans, 2);
END;
$$ LANGUAGE plpgsql;

SELECT MedianaMargenMovil(to_date('2011-09-01', 'YYYY-MM-DD'), 5);
SELECT MedianaMargenMovil(to_date('2012-11-01', 'YYYY-MM-DD'), 4);


CREATE VIEW UNION_CAT (year, category, revenue, cost, margin, category_type)
AS
SELECT EXTRACT(YEAR FROM sales_date) AS sales_year,
       product_type                  AS category,
       SUM(revenue)                  AS rev_sum,
       SUM(cost)                     AS cost_sum,
       SUM(revenue - cost)           AS diff_sum,
       'Product Type'                AS category_type
FROM definitiva
GROUP BY category, sales_year

UNION

SELECT EXTRACT(YEAR FROM sales_date) AS sales_year,
       customer_type                 AS category,
       SUM(revenue)                  AS rev_sum,
       SUM(cost)                     AS cost_sum,
       SUM(revenue - cost)           AS diff_sum,
       'Customer Type'               AS category_type
FROM definitiva
GROUP BY category, sales_year

UNION

SELECT EXTRACT(YEAR FROM sales_date) AS sales_year,
       sales_channel                 AS category,
       SUM(revenue)                  AS rev_sum,
       SUM(cost)                     AS cost_sum,
       SUM(revenue - cost)           AS diff_sum,
       'Sales Channel'               AS category_type
FROM definitiva
GROUP BY category, sales_year

ORDER BY sales_year, category_type, category;


CREATE OR REPLACE FUNCTION getTotals(year IN INTEGER) RETURNS RECORD
AS
$$

DECLARE
    totals RECORD;
BEGIN
    SELECT SUM(revenue) as acum_rev, SUM(cost) as acum_cost, SUM(revenue - cost) as acum_margin
    FROM definitiva
    WHERE EXTRACT(YEAR FROM sales_date) = year
    INTO totals;
    return totals;
END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION ReporteVentas(n IN INTEGER) RETURNS VOID
AS
$$
DECLARE
    TOTALYEAR     RECORD;
    year_ant      INTEGER := -1;
    year_to_print TEXT;
    CSALES CURSOR FOR
        SELECT *
        FROM UNION_CAT
        WHERE year < (SELECT MIN(year) FROM UNION_CAT) + n;
    RCSALES       RECORD;
BEGIN
    IF (n < 0) THEN
        raise notice 'La cantidad de años debe ser positiva';
        RETURN;
    END IF;
    OPEN CSALES;
    LOOP
        FETCH CSALES INTO RCSALES;
        EXIT WHEN NOT FOUND;
        IF year_ant != RCSALES.year THEN
            IF year_ant != -1 THEN
                TOTALYEAR = getTotals(year_ant);
                raise notice '--------------------------------------------------------  %   %   %',
                    ROUND(TOTALYEAR.acum_rev), ROUND(TOTALYEAR.acum_cost), ROUND(TOTALYEAR.acum_margin);
            ELSE
                raise notice '--------------------------------------------HISTORIC SALES REPORT---------------------------------------------------';
                raise notice '---------------------------------------------------------------------------------------------------------------------';
                raise notice 'Year--------Category-------------------------------------------Revenue------Cost------ Margin-----------------------';
            END IF;
            raise notice '---------------------------------------------------------------------------------------------------------------------';
            year_to_print := CAST(RCSALES.year AS TEXT);
            year_ant := RCSALES.year;
        ELSE
            year_to_print := '----';
        END IF;

        raise notice '%   %: %                               %   %   %',
            year_to_print, RCSALES.category_type,RCSALES.category,ROUND(RCSALES.revenue),ROUND(RCSALES.cost),ROUND(RCSALES.margin);
    END LOOP;

    IF year_ant != -1 THEN
        TOTALYEAR = getTotals(year_ant);
        raise notice '--------------------------------------------------------  %   %   %', ROUND(TOTALYEAR.acum_rev), ROUND(TOTALYEAR.acum_cost), ROUND(TOTALYEAR.acum_margin);
    END IF;

    CLOSE CSALES;
END
$$ LANGUAGE PLPGSQL;

SELECT ReporteVentas(0);