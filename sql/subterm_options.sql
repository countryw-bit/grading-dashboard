WITH p AS (
    SELECT
        UPPER(:term_code) AS selected_term,
        CASE
            WHEN UPPER(:term_code) LIKE '%SUMM'
                THEN SUBSTR(UPPER(:term_code), 1, LENGTH(UPPER(:term_code)) - 1)
            ELSE UPPER(:term_code)
        END AS term_prefix
    FROM dual
)
SELECT
    a.id,
    a.cd AS subterm_code,
    a.name AS subterm_name,
    a.start_dt,
    a.end_dt
FROM {{SCHEMA}}.ksen_atp a
CROSS JOIN p
WHERE UPPER(a.cd) LIKE p.term_prefix || '%'
  AND UPPER(a.cd) <> p.selected_term
  AND a.name IS NOT NULL
  AND UPPER(a.name) NOT LIKE '%FINAL EXAM%'
ORDER BY a.start_dt, a.cd
