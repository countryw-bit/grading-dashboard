SELECT
    a.id,
    a.cd AS term_code,
    a.name AS term_name,
    a.start_dt,
    a.end_dt
FROM {{SCHEMA}}.ksen_atp a
WHERE a.cd IS NOT NULL
  AND a.name IS NOT NULL
  AND UPPER(a.name) NOT LIKE '%FINAL EXAM%'
  AND REGEXP_LIKE(UPPER(a.cd), '^[0-9]{4}(FALL|SUMM|SPRG)$')
ORDER BY a.start_dt DESC NULLS LAST, a.cd DESC
