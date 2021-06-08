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
    revenue       FLOAT CHECK (revenue > 0),
    cost          FLOAT CHECK (cost > 0),
    PRIMARY KEY (month, week, product_type, territory, sales_channel, customer_type)
);


CREATE TABLE definitiva
(
    sales_date    DATE not NULL,
    product_type  TEXT NOT NULL,
    territory     TEXT NOT NULL,
    sales_channel TEXT NOT NULL CHECK (sales_channel IN ('Direct', 'Internet', 'Retail')),
    customer_type TEXT NOT NULL,
    revenue       FLOAT CHECK (revenue > 0),
    cost          FLOAT CHECK (cost > 0),
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
    yearStr  TEXT;
    monthStr TEXT;
    dayStr   TEXT;
BEGIN
    yearStr := SUBSTRING(quarter, 4, 7);
    SELECT CAST(EXTRACT(MONTH FROM TO_DATE(SUBSTRING(month, 4, 6), 'Mon')) AS TEXT) INTO monthStr;
    monthStr := LPAD(monthStr, 2, '0');
    CASE (SUBSTRING(week, 1, 2))
        WHEN 'W1' then dayStr := '01';
        WHEN 'W2' then dayStr := '08';
        WHEN 'W3' then dayStr := '15';
        WHEN 'W4' then dayStr := '22';
        WHEN 'W5' then dayStr := '29';
        END CASE;
    RETURN TO_DATE(yearStr || monthStr || dayStr, 'YYYYMMDD');
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION intToDef() RETURNS trigger AS
$intToDef$
BEGIN
    INSERT INTO definitiva
    VALUES (toDate(new.quarter, new.week, new.month), new.product_type, new.territory, new.sales_channel,
            new.customer_type,
            new.revenue, new.cost);
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
      and sales_date > limit_date
    INTO ans;

    RETURN ROUND(ans, 2);
END;
$$ LANGUAGE plpgsql;

SELECT MedianaMargenMovil(to_date('2011-09-01', 'YYYY-MM-DD'), 5);


CREATE VIEW unionCat (year, category, revenue, cost, margin, categoryType)
AS SELECT EXTRACT(YEAR FROM sales_date) as salesYear, product_type as category,
sum(revenue) as revSum,sum(cost) as costSum,sum(revenue-cost) as diffSum, 'Product Type' as categoryType
FROM definitiva
GROUP BY category,salesYear

UNION

SELECT EXTRACT(YEAR FROM sales_date) as salesYear, customer_type as category,
sum(revenue) as revSum,sum(cost) as costSum,sum(revenue-cost) as diffSum, 'Customer Type' as categoryType
FROM definitiva
GROUP BY category,salesYear

UNION

SELECT EXTRACT(YEAR FROM sales_date) as salesYear, sales_channel as category,
sum(revenue) as revSum,sum(cost) as costSum,sum(revenue-cost) as diffSum, 'Sales Channel' as categoryType
FROM definitiva
GROUP BY category,salesYear

ORDER BY salesYear,categoryType,category;


CREATE OR REPLACE FUNCTION getTotals(
year IN INTEGER
) RETURNS RECORD
AS $$

DECLARE
totals RECORD;
BEGIN
	SELECT sum(revenue) as acumRev,sum(cost) as acumCost,sum(revenue-cost) as acumMargin
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
    TOTALYEAR RECORD;
    yearAnt integer;
    CSALES CURSOR FOR
        SELECT year, category, revenue, cost, margin, categoryType
        from unionCat where year < (SELECT min(year) from unionCat) + n;
    RCSALES RECORD;
BEGIN
    IF (n < 0) THEN
        raise notice 'La cantidad de años debe ser positiva';
        RETURN;
    END IF;
    yearAnt = 0;
    OPEN CSALES;
    LOOP
    FETCH CSALES INTO RCSALES;
    EXIT WHEN NOT FOUND;
    IF yearAnt=0 then
        raise notice  '-----------------HISTORIC SALES REPORT-----------------------';
        raise notice  'Year-------------Category------------Revenue----------Cost---------------- Margin--------------------------';
        SELECT RCSALES.year INTO yearAnt;
        raise notice '%',RCSALES.year ;
    ELSE IF yearAnt < RCSALES.year THEN
        TOTALYEAR = getTotals(yearAnt);
        raise notice  '% % %', TOTALYEAR.acumRev, TOTALYEAR.acumCost, TOTALYEAR.acumMargin;
        SELECT RCSALES.year INTO yearAnt;
        raise notice '%',RCSALES.year ;
    end if;
    END IF;
        raise notice '%: % % %',RCSALES.categoryType,RCSALES.category,RCSALES.cost,RCSALES.margin;
    END LOOP;
    if yearAnt !=0 then
    TOTALYEAR = getTotals(yearAnt);
    raise notice  '% % %', TOTALYEAR.acumRev, TOTALYEAR.acumCost, TOTALYEAR.acumMargin;
    end if;
    CLOSE CSALES;
    END
$$ LANGUAGE PLPGSQL;

SELECT ReporteVentas(2);