/*
Registration vs. grading-roster population summary.

Verified section crosswalk used here:
  KSEN_ROSTER.REF_ID                -> activity offering
  KSEN_ROSTER_ROW.REF_ID            -> KSEN_COURSE_REG_REG.ID

The registration population includes active registrations that can be mapped to
an exact activity offering through any term roster row, including historical,
removed, and abandoned rows. It deliberately does not match on COURSE_CODE.
See README.txt for the remaining never-rostered registration limitation.
*/
WITH term_parameters AS (
    SELECT
        UPPER(:term_code) AS selected_term,
        CASE
            WHEN UPPER(:term_code) LIKE '%SUMM'
            THEN SUBSTR(UPPER(:term_code), 1, LENGTH(UPPER(:term_code)) - 1)
            ELSE UPPER(:term_code)
        END AS term_prefix
    FROM dual
),
selected_atps AS (
    SELECT a.id, a.cd, a.name
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
all_term_rosters AS (
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
             )
            THEN 'Y' ELSE 'N'
        END AS current_roster_ind,
        CASE
            WHEN r.roster_state = 'kuali.grading.roster.state.abandoned'
            THEN 'Y' ELSE 'N'
        END AS abandoned_roster_ind
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a ON a.id = r.atp_id
    WHERE r.ref_id IS NOT NULL
),
registration_ao_map AS (
    SELECT DISTINCT
        atr.activity_offering_id,
        rr.ref_id AS registration_id
    FROM all_term_rosters atr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = atr.roster_id
    WHERE rr.ref_id IS NOT NULL
),
active_registrations AS (
    SELECT DISTINCT
        ram.activity_offering_id,
        reg.id AS registration_id,
        reg.pers_id,
        reg.course_code,
        reg.reg_state,
        reg.eff_dt AS registration_eff_dt,
        reg.exp_dt AS registration_exp_dt
    FROM registration_ao_map ram
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = ram.registration_id
    JOIN selected_atps a
      ON a.id = reg.term_id
    WHERE reg.reg_state =
          'kuali.courseregistration.registration.state.active'
      AND (reg.eff_dt IS NULL OR reg.eff_dt <= SYSTIMESTAMP)
      AND (reg.exp_dt IS NULL OR reg.exp_dt > SYSTIMESTAMP)
),
current_roster_groups AS (
    SELECT
        activity_offering_id,
        roster_type,
        MIN(subterm_code) AS subterm_code,
        MIN(subterm_name) AS subterm_name,
        MIN(roster_name) AS roster_name,
        COUNT(DISTINCT roster_id) AS current_roster_count,
        LISTAGG(roster_id, ', ') WITHIN GROUP (ORDER BY roster_id)
            AS current_roster_ids,
        LISTAGG(DISTINCT roster_state, ', ')
            WITHIN GROUP (ORDER BY roster_state) AS current_roster_states
    FROM all_term_rosters
    WHERE current_roster_ind = 'Y'
    GROUP BY activity_offering_id, roster_type
),
activity_offerings_with_registrations AS (
    SELECT DISTINCT activity_offering_id
    FROM active_registrations
),
workflow_units AS (
    SELECT
        crg.activity_offering_id,
        crg.roster_type,
        crg.subterm_code,
        crg.subterm_name,
        crg.roster_name,
        crg.current_roster_count,
        crg.current_roster_ids,
        crg.current_roster_states
    FROM current_roster_groups crg
    UNION ALL
    SELECT
        aor.activity_offering_id,
        CAST('(no current roster)' AS VARCHAR2(255)) AS roster_type,
        MIN(atr.subterm_code),
        MIN(atr.subterm_name),
        MIN(atr.roster_name),
        0,
        CAST(NULL AS VARCHAR2(4000)),
        CAST(NULL AS VARCHAR2(4000))
    FROM activity_offerings_with_registrations aor
    JOIN all_term_rosters atr
      ON atr.activity_offering_id = aor.activity_offering_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM current_roster_groups crg
        WHERE crg.activity_offering_id = aor.activity_offering_id
    )
    GROUP BY aor.activity_offering_id
),
grading_population AS (
    SELECT DISTINCT
        atr.activity_offering_id,
        atr.roster_type,
        NVL(reg.pers_id, 'UNRESOLVED:' || rr.ref_id) AS pers_id,
        rr.ref_id AS registration_id
    FROM all_term_rosters atr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = atr.roster_id
     AND rr.roster_row_state <>
         'kuali.grading.roster.row.state.removed'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    WHERE atr.current_roster_ind = 'Y'
),
abandoned_inventory AS (
    SELECT
        activity_offering_id,
        COUNT(DISTINCT CASE WHEN abandoned_roster_ind = 'Y' THEN roster_id END)
            AS abandoned_roster_count
    FROM all_term_rosters
    GROUP BY activity_offering_id
),
stranded_active AS (
    SELECT DISTINCT
        atr.activity_offering_id,
        reg.pers_id
    FROM all_term_rosters atr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = atr.roster_id
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    WHERE reg.reg_state =
          'kuali.courseregistration.registration.state.active'
      AND (reg.eff_dt IS NULL OR reg.eff_dt <= SYSTIMESTAMP)
      AND (reg.exp_dt IS NULL OR reg.exp_dt > SYSTIMESTAMP)
      AND (
             atr.abandoned_roster_ind = 'Y'
          OR rr.roster_row_state =
             'kuali.grading.roster.row.state.removed'
      )
      AND NOT EXISTS (
          SELECT 1
          FROM grading_population gp
          WHERE gp.activity_offering_id = atr.activity_offering_id
            AND gp.pers_id = reg.pers_id
      )
),
workflow_students AS (
    SELECT
        wu.activity_offering_id,
        wu.roster_type,
        ar.pers_id AS registration_pers_id,
        gp.pers_id AS grading_pers_id
    FROM workflow_units wu
    LEFT JOIN active_registrations ar
      ON ar.activity_offering_id = wu.activity_offering_id
    FULL OUTER JOIN grading_population gp
      ON gp.activity_offering_id = wu.activity_offering_id
     AND gp.roster_type = wu.roster_type
     AND gp.pers_id = ar.pers_id
),
population_counts AS (
    SELECT
        activity_offering_id,
        roster_type,
        COUNT(DISTINCT registration_pers_id) AS registration_student_count,
        COUNT(DISTINCT grading_pers_id) AS grading_student_count,
        COUNT(DISTINCT CASE
            WHEN registration_pers_id IS NOT NULL
             AND grading_pers_id IS NULL
            THEN registration_pers_id END) AS missing_from_grading_count,
        COUNT(DISTINCT CASE
            WHEN registration_pers_id IS NULL
             AND grading_pers_id IS NOT NULL
            THEN grading_pers_id END) AS not_active_registration_count,
        COUNT(DISTINCT CASE
            WHEN registration_pers_id IS NOT NULL
             AND grading_pers_id IS NOT NULL
            THEN registration_pers_id END) AS matched_student_count
    FROM workflow_students
    GROUP BY activity_offering_id, roster_type
),
course_codes AS (
    SELECT
        activity_offering_id,
        LISTAGG(course_code, ', ')
            WITHIN GROUP (ORDER BY course_code) AS course_codes
    FROM (
        SELECT DISTINCT activity_offering_id, course_code
        FROM active_registrations
        WHERE course_code IS NOT NULL
    )
    GROUP BY activity_offering_id
)
SELECT
    wu.subterm_code,
    wu.subterm_name,
    NVL(cc.course_codes, wu.roster_name) AS course_code,
    wu.roster_name AS course_name,
    wu.activity_offering_id,
    wu.roster_type,
    wu.current_roster_ids,
    wu.current_roster_states,
    wu.current_roster_count,
    NVL(ai.abandoned_roster_count, 0) AS abandoned_roster_count,
    NVL(pc.registration_student_count, 0) AS registration_student_count,
    NVL(pc.grading_student_count, 0) AS grading_student_count,
    NVL(pc.missing_from_grading_count, 0) AS missing_from_grading_count,
    NVL(pc.not_active_registration_count, 0)
        AS not_active_registration_count,
    NVL(pc.matched_student_count, 0) AS matched_student_count,
    (SELECT COUNT(DISTINCT sa.pers_id)
       FROM stranded_active sa
      WHERE sa.activity_offering_id = wu.activity_offering_id)
        AS stranded_active_student_count,
    CASE
        WHEN wu.current_roster_count = 0
        THEN 'NO_CURRENT_GRADING_ROSTER'
        WHEN wu.current_roster_count > 1
         AND (NVL(pc.missing_from_grading_count, 0) > 0
           OR NVL(pc.not_active_registration_count, 0) > 0)
        THEN 'MIXED_DISCREPANCY'
        WHEN wu.current_roster_count > 1
        THEN 'MULTIPLE_CURRENT_ROSTERS'
        WHEN NVL(pc.registration_student_count, 0) =
             NVL(pc.grading_student_count, 0)
         AND NVL(pc.missing_from_grading_count, 0) > 0
         AND NVL(pc.not_active_registration_count, 0) > 0
        THEN 'COUNTS_MATCH_STUDENTS_DIFFER'
        WHEN NVL(pc.missing_from_grading_count, 0) > 0
         AND NVL(pc.not_active_registration_count, 0) > 0
        THEN 'MIXED_DISCREPANCY'
        WHEN NVL(pc.missing_from_grading_count, 0) > 0
        THEN 'REGISTRATION_GREATER'
        WHEN NVL(pc.not_active_registration_count, 0) > 0
        THEN 'GRADING_GREATER'
        WHEN (SELECT COUNT(DISTINCT sa.pers_id)
                FROM stranded_active sa
               WHERE sa.activity_offering_id = wu.activity_offering_id) > 0
        THEN 'ACTIVE_STUDENTS_ON_ABANDONED_ROSTER'
        ELSE 'MATCH'
    END AS discrepancy_type,
    CASE
        WHEN wu.current_roster_count = 0
          OR NVL(pc.missing_from_grading_count, 0) > 0
        THEN 'HIGH'
        WHEN NVL(pc.not_active_registration_count, 0) > 0
          OR wu.current_roster_count > 1
          OR (SELECT COUNT(DISTINCT sa.pers_id)
                FROM stranded_active sa
               WHERE sa.activity_offering_id = wu.activity_offering_id) > 0
        THEN 'REVIEW'
        ELSE 'OK'
    END AS review_status,
    'ROSTER_ROW_REGISTRATION_CROSSWALK' AS registration_source
FROM workflow_units wu
LEFT JOIN population_counts pc
  ON pc.activity_offering_id = wu.activity_offering_id
 AND pc.roster_type = wu.roster_type
LEFT JOIN abandoned_inventory ai
  ON ai.activity_offering_id = wu.activity_offering_id
LEFT JOIN course_codes cc
  ON cc.activity_offering_id = wu.activity_offering_id
ORDER BY
    CASE WHEN review_status = 'HIGH' THEN 0
         WHEN review_status = 'REVIEW' THEN 1 ELSE 2 END,
    wu.subterm_code,
    course_code,
    wu.roster_type
FETCH FIRST 10000 ROWS ONLY
