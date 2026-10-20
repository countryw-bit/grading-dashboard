/*
Term-wide student discrepancy export. This replaces thousands of per-section
HTTP/Oracle calls with one term-scoped query.
*/
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
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
all_rosters AS (
    SELECT
        r.id AS roster_id,
        r.ref_id AS activity_offering_id,
        r.name AS roster_name,
        r.roster_type,
        r.roster_state,
        r.atp_id,
        a.cd AS subterm_code,
        a.name AS subterm_name,
        CASE
            WHEN (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
             AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
             AND r.roster_state IN (
                 'kuali.grading.roster.state.submitted',
                 'kuali.grading.roster.state.partial.submitted',
                 'kuali.grading.roster.state.notstarted'
             ) THEN 'Y' ELSE 'N'
        END AS current_roster_ind
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a ON a.id = r.atp_id
    WHERE r.ref_id IS NOT NULL
),
registration_ao_map AS (
    SELECT DISTINCT
        r.activity_offering_id,
        rr.ref_id AS registration_id
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr ON rr.roster_id = r.roster_id
    WHERE rr.ref_id IS NOT NULL
),
active_registration_candidates AS (
    SELECT
        m.activity_offering_id,
        reg.pers_id,
        reg.id AS registration_id,
        reg.reg_state,
        reg.eff_dt AS registration_eff_dt,
        reg.exp_dt AS registration_exp_dt,
        reg.course_code,
        ROW_NUMBER() OVER (
            PARTITION BY m.activity_offering_id, reg.pers_id
            ORDER BY reg.updatetime DESC NULLS LAST,
                     reg.createtime DESC NULLS LAST,
                     reg.id
        ) AS registration_rank
    FROM registration_ao_map m
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg ON reg.id = m.registration_id
    JOIN selected_atps a ON a.id = reg.term_id
    WHERE reg.reg_state =
          'kuali.courseregistration.registration.state.active'
      AND (reg.eff_dt IS NULL OR reg.eff_dt <= SYSTIMESTAMP)
      AND (reg.exp_dt IS NULL OR reg.exp_dt > SYSTIMESTAMP)
),
active_registrations AS (
    SELECT *
    FROM active_registration_candidates
    WHERE registration_rank = 1
),
current_roster_groups AS (
    SELECT
        activity_offering_id,
        roster_type,
        MIN(subterm_code) AS subterm_code,
        MIN(subterm_name) AS subterm_name,
        MIN(roster_name) AS roster_name,
        LISTAGG(roster_id, ', ') WITHIN GROUP (ORDER BY roster_id)
            AS current_roster_ids,
        LISTAGG(DISTINCT roster_state, ', ')
            WITHIN GROUP (ORDER BY roster_state) AS current_roster_states
    FROM all_rosters
    WHERE current_roster_ind = 'Y'
    GROUP BY activity_offering_id, roster_type
),
workflow_units AS (
    SELECT
        g.activity_offering_id,
        g.roster_type,
        g.subterm_code,
        g.subterm_name,
        g.roster_name,
        g.current_roster_ids,
        g.current_roster_states
    FROM current_roster_groups g
    UNION ALL
    SELECT
        ar.activity_offering_id,
        CAST('(no current roster)' AS VARCHAR2(255)),
        MIN(r.subterm_code),
        MIN(r.subterm_name),
        MIN(r.roster_name),
        CAST(NULL AS VARCHAR2(4000)),
        CAST(NULL AS VARCHAR2(4000))
    FROM active_registrations ar
    JOIN all_rosters r
      ON r.activity_offering_id = ar.activity_offering_id
    WHERE NOT EXISTS (
        SELECT 1 FROM current_roster_groups g
        WHERE g.activity_offering_id = ar.activity_offering_id
    )
    GROUP BY ar.activity_offering_id
),
grading_candidates AS (
    SELECT
        r.activity_offering_id,
        r.roster_type,
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
            PARTITION BY r.activity_offering_id, r.roster_type,
                         NVL(reg.pers_id, 'UNRESOLVED:' || rr.ref_id)
            ORDER BY rr.updatetime DESC NULLS LAST, rr.id
        ) AS person_rank
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = r.roster_id
     AND rr.roster_row_state <>
         'kuali.grading.roster.row.state.removed'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_course_reg_reg reg ON reg.id = rr.ref_id
    WHERE r.current_roster_ind = 'Y'
),
grading_population AS (
    SELECT * FROM grading_candidates WHERE person_rank = 1
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
        r.activity_offering_id,
        reg.pers_id,
        LISTAGG(DISTINCT r.roster_id, ', ')
            WITHIN GROUP (ORDER BY r.roster_id) AS historical_roster_ids,
        LISTAGG(DISTINCT r.roster_state, ', ')
            WITHIN GROUP (ORDER BY r.roster_state) AS historical_roster_states,
        LISTAGG(DISTINCT rr.roster_row_state, ', ')
            WITHIN GROUP (ORDER BY rr.roster_row_state)
            AS historical_row_states
    FROM all_rosters r
    JOIN {{SCHEMA}}.ksen_roster_row rr ON rr.roster_id = r.roster_id
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg ON reg.id = rr.ref_id
    WHERE r.current_roster_ind = 'N'
       OR rr.roster_row_state =
          'kuali.grading.roster.row.state.removed'
    GROUP BY r.activity_offering_id, reg.pers_id
),
missing_from_grading AS (
    SELECT
        wu.subterm_code,
        wu.subterm_name,
        ar.course_code,
        wu.roster_name,
        wu.activity_offering_id,
        wu.roster_type,
        ar.pers_id,
        ar.registration_id,
        ar.reg_state AS registration_state,
        ar.registration_eff_dt,
        ar.registration_exp_dt,
        CAST(NULL AS VARCHAR2(255)) AS roster_id,
        CAST(NULL AS VARCHAR2(255)) AS roster_state,
        CAST(NULL AS VARCHAR2(255)) AS roster_row_id,
        CAST(NULL AS VARCHAR2(255)) AS roster_row_state,
        'Y' AS on_registration_roster,
        'N' AS on_grading_roster,
        'MISSING_FROM_GRADING' AS student_discrepancy_type,
        wu.current_roster_ids,
        wu.current_roster_states
    FROM workflow_units wu
    JOIN active_registrations ar
      ON ar.activity_offering_id = wu.activity_offering_id
    WHERE NOT EXISTS (
        SELECT 1 FROM grading_population gp
        WHERE gp.activity_offering_id = wu.activity_offering_id
          AND gp.roster_type = wu.roster_type
          AND gp.pers_id = ar.pers_id
    )
),
not_active_registration AS (
    SELECT
        wu.subterm_code,
        wu.subterm_name,
        gp.course_code,
        wu.roster_name,
        wu.activity_offering_id,
        wu.roster_type,
        gp.pers_id,
        gp.registration_id,
        gp.reg_state AS registration_state,
        gp.registration_eff_dt,
        gp.registration_exp_dt,
        gp.roster_id,
        gp.roster_state,
        gp.roster_row_id,
        gp.roster_row_state,
        'N' AS on_registration_roster,
        'Y' AS on_grading_roster,
        'NOT_ACTIVE_IN_REGISTRATION' AS student_discrepancy_type,
        wu.current_roster_ids,
        wu.current_roster_states
    FROM workflow_units wu
    JOIN grading_population gp
      ON gp.activity_offering_id = wu.activity_offering_id
     AND gp.roster_type = wu.roster_type
    WHERE NOT EXISTS (
        SELECT 1 FROM active_registrations ar
        WHERE ar.activity_offering_id = wu.activity_offering_id
          AND ar.pers_id = gp.pers_id
    )
),
discrepancies AS (
    SELECT * FROM missing_from_grading
    UNION ALL
    SELECT * FROM not_active_registration
)
SELECT
    d.subterm_code,
    d.subterm_name,
    d.course_code,
    d.roster_name AS course_name,
    d.activity_offering_id,
    d.roster_type,
    d.pers_id AS student_id,
    NVL(pn.composite_name, d.pers_id) AS student_name,
    d.registration_id,
    d.registration_state,
    d.registration_eff_dt,
    d.registration_exp_dt,
    d.roster_id,
    d.roster_state,
    d.roster_row_id,
    d.roster_row_state,
    d.on_registration_roster,
    d.on_grading_roster,
    d.student_discrepancy_type,
    d.current_roster_ids,
    d.current_roster_states,
    hl.historical_roster_ids,
    hl.historical_roster_states,
    hl.historical_row_states
FROM discrepancies d
LEFT JOIN preferred_person_name pn ON pn.pers_id = d.pers_id
LEFT JOIN historical_location hl
  ON hl.activity_offering_id = d.activity_offering_id
 AND hl.pers_id = d.pers_id
ORDER BY d.subterm_code, d.course_code, d.roster_type,
         d.student_discrepancy_type, student_name, d.pers_id
FETCH FIRST 50000 ROWS ONLY
