/* Student-level drill-down for one exact activity offering and workflow. */
WITH term_parameters AS (
    SELECT
        UPPER(:term_code) AS selected_term,
        CASE WHEN UPPER(:term_code) LIKE '%SUMM'
             THEN SUBSTR(UPPER(:term_code), 1, LENGTH(UPPER(:term_code)) - 1)
             ELSE UPPER(:term_code) END AS term_prefix
    FROM dual
),
selected_atps AS (
    SELECT a.id
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
all_rosters AS (
    SELECT
        r.id AS roster_id,
        r.ref_id AS activity_offering_id,
        r.roster_type,
        r.roster_state,
        CASE
            WHEN (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
             AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
             AND r.roster_state IN (
                 'kuali.grading.roster.state.submitted',
                 'kuali.grading.roster.state.partial.submitted',
                 'kuali.grading.roster.state.notstarted'
             )
            THEN 'Y' ELSE 'N'
        END AS current_roster_ind
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a ON a.id = r.atp_id
    WHERE r.ref_id = :activity_offering_id
),
registration_population AS (
    SELECT DISTINCT
        reg.pers_id,
        reg.id AS registration_id,
        reg.reg_state,
        reg.eff_dt AS registration_eff_dt,
        reg.exp_dt AS registration_exp_dt,
        reg.course_code
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = r.roster_id
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    WHERE reg.reg_state =
          'kuali.courseregistration.registration.state.active'
      AND (reg.eff_dt IS NULL OR reg.eff_dt <= SYSTIMESTAMP)
      AND (reg.exp_dt IS NULL OR reg.exp_dt > SYSTIMESTAMP)
),
grading_population AS (
    SELECT
        NVL(reg.pers_id, 'UNRESOLVED:' || rr.ref_id) AS pers_id,
        rr.ref_id AS registration_id,
        reg.reg_state,
        reg.eff_dt AS registration_eff_dt,
        reg.exp_dt AS registration_exp_dt,
        reg.course_code,
        r.roster_id,
        r.roster_state,
        rr.id AS roster_row_id,
        rr.roster_row_state,
        ROW_NUMBER() OVER (
            PARTITION BY NVL(reg.pers_id, 'UNRESOLVED:' || rr.ref_id)
            ORDER BY rr.updatetime DESC NULLS LAST, rr.id
        ) AS person_rank
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = r.roster_id
     AND rr.roster_row_state <>
         'kuali.grading.roster.row.state.removed'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    WHERE r.current_roster_ind = 'Y'
      AND r.roster_type = :roster_type
),
grading_people AS (
    SELECT * FROM grading_population WHERE person_rank = 1
),
people AS (
    SELECT pers_id FROM registration_population
    UNION
    SELECT pers_id FROM grading_people
),
preferred_person_name AS (
    SELECT pers_id, composite_name
    FROM (
        SELECT
            pn.pers_id,
            pn.composite_name,
            ROW_NUMBER() OVER (
                PARTITION BY pn.pers_id
                ORDER BY
                    CASE WHEN pn.pers_name_state =
                        'kuali.person.person.name.state.active'
                    THEN 0 ELSE 1 END,
                    CASE WHEN pn.exp_dt IS NULL THEN 0 ELSE 1 END,
                    pn.eff_dt DESC NULLS LAST,
                    pn.updatetime DESC NULLS LAST,
                    pn.id
            ) AS rn
        FROM {{SCHEMA}}.ksen_pers_name pn
        WHERE (pn.eff_dt IS NULL OR pn.eff_dt <= SYSTIMESTAMP)
          AND (pn.exp_dt IS NULL OR pn.exp_dt > SYSTIMESTAMP)
    )
    WHERE rn = 1
),
historical_location AS (
    SELECT
        reg.pers_id,
        LISTAGG(DISTINCT r.roster_id, ', ')
            WITHIN GROUP (ORDER BY r.roster_id) AS historical_roster_ids,
        LISTAGG(DISTINCT r.roster_state, ', ')
            WITHIN GROUP (ORDER BY r.roster_state) AS historical_roster_states,
        LISTAGG(DISTINCT rr.roster_row_state, ', ')
            WITHIN GROUP (ORDER BY rr.roster_row_state)
            AS historical_row_states
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = r.roster_id
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    WHERE r.current_roster_ind = 'N'
       OR rr.roster_row_state =
          'kuali.grading.roster.row.state.removed'
    GROUP BY reg.pers_id
)
SELECT
    p.pers_id AS student_id,
    NVL(pn.composite_name, p.pers_id) AS student_name,
    NVL(rp.registration_id, gp.registration_id) AS registration_id,
    NVL(rp.reg_state, gp.reg_state) AS registration_state,
    NVL(rp.registration_eff_dt, gp.registration_eff_dt)
        AS registration_eff_dt,
    NVL(rp.registration_exp_dt, gp.registration_exp_dt)
        AS registration_exp_dt,
    NVL(rp.course_code, gp.course_code) AS course_code,
    gp.roster_id,
    gp.roster_state,
    gp.roster_row_id,
    gp.roster_row_state,
    CASE WHEN rp.pers_id IS NOT NULL THEN 'Y' ELSE 'N' END
        AS on_registration_roster,
    CASE WHEN gp.pers_id IS NOT NULL THEN 'Y' ELSE 'N' END
        AS on_grading_roster,
    CASE
        WHEN rp.pers_id IS NOT NULL AND gp.pers_id IS NULL
        THEN 'MISSING_FROM_GRADING'
        WHEN rp.pers_id IS NULL AND gp.pers_id IS NOT NULL
        THEN 'NOT_ACTIVE_IN_REGISTRATION'
        ELSE 'MATCHED'
    END AS student_discrepancy_type,
    hl.historical_roster_ids,
    hl.historical_roster_states,
    hl.historical_row_states
FROM people p
LEFT JOIN registration_population rp ON rp.pers_id = p.pers_id
LEFT JOIN grading_people gp ON gp.pers_id = p.pers_id
LEFT JOIN preferred_person_name pn ON pn.pers_id = p.pers_id
LEFT JOIN historical_location hl ON hl.pers_id = p.pers_id
ORDER BY
    CASE
        WHEN rp.pers_id IS NOT NULL AND gp.pers_id IS NULL THEN 0
        WHEN rp.pers_id IS NULL AND gp.pers_id IS NOT NULL THEN 1
        ELSE 2
    END,
    student_name,
    student_id
FETCH FIRST 10000 ROWS ONLY
