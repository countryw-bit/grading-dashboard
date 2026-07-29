WITH term_parameters AS (
    SELECT
        UPPER(:term_code) AS selected_term,
        CASE WHEN UPPER(:term_code) LIKE '%SUMM'
             THEN SUBSTR(UPPER(:term_code), 1, LENGTH(UPPER(:term_code)) - 1)
             ELSE UPPER(:term_code) END AS term_prefix
    FROM dual
),
selected_atps AS (
    SELECT a.id, a.cd, a.name
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE (UPPER(a.cd) = p.selected_term OR UPPER(a.cd) LIKE p.term_prefix || '%')
),
active_rosters AS (
    SELECT
        a.cd AS subterm_code,
        a.name AS subterm_name,
        r.ref_id AS activity_offering_id,
        r.roster_type,
        r.id AS roster_id
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a ON a.id = r.atp_id
    WHERE (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
      AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
      AND r.roster_state IN (
          'kuali.grading.roster.state.submitted',
          'kuali.grading.roster.state.partial.submitted',
          'kuali.grading.roster.state.notstarted'
      )
)
SELECT
    subterm_code,
    subterm_name,
    activity_offering_id,
    roster_type,
    COUNT(DISTINCT roster_id) AS roster_count,
    LISTAGG(roster_id, ', ') WITHIN GROUP (ORDER BY roster_id) AS roster_ids
FROM active_rosters
GROUP BY subterm_code, subterm_name, activity_offering_id, roster_type
HAVING COUNT(DISTINCT roster_id) > 1
ORDER BY subterm_code, activity_offering_id, roster_type
FETCH FIRST 2000 ROWS ONLY

