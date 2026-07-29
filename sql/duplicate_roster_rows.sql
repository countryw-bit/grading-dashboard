WITH term_parameters AS (
    SELECT
        UPPER(:term_code) AS selected_term,
        CASE
            WHEN UPPER(:term_code) LIKE '%SUMM'
                THEN SUBSTR(
                    UPPER(:term_code),
                    1,
                    LENGTH(UPPER(:term_code)) - 1
                )
            ELSE UPPER(:term_code)
        END AS term_prefix
    FROM dual
),
selected_atps AS (
    SELECT
        a.id,
        a.cd,
        a.name
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
term_rosters AS (
    SELECT
        r.id AS roster_id,
        r.ref_id AS activity_offering_id,
        r.name AS roster_name,
        r.roster_type,
        r.atp_id,
        a.cd AS subterm_code,
        a.name AS subterm_name
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a
      ON a.id = r.atp_id
    WHERE (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
      AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
),
/*
Find one user-facing, eight-digit Eagle ID for an internal KSEN person ID.
The roster-row REF_ID points to KSEN_COURSE_REG_REG.ID in this environment.
KSEN_COURSE_REG_REG.PERS_ID is the user-facing eight-digit Eagle ID.
The roster-row IDENTIFIER field is not used as the primary crosswalk.
*/
person_eagle_ids AS (
    SELECT
        pers_id,
        identifier AS eagle_id
    FROM (
        SELECT
            pi.pers_id,
            pi.identifier,
            ROW_NUMBER() OVER (
                PARTITION BY pi.pers_id
                ORDER BY
                    CASE
                        WHEN pi.pers_id_state =
                             'kuali.person.person.identifier.state.active'
                        THEN 0
                        ELSE 1
                    END,
                    CASE WHEN pi.exp_dt IS NULL THEN 0 ELSE 1 END,
                    pi.eff_dt DESC NULLS LAST,
                    pi.id
            ) AS rn
        FROM {{SCHEMA}}.ksen_pers_id pi
        WHERE REGEXP_LIKE(TRIM(pi.identifier), '^[0-9]{8}$')
          AND (pi.eff_dt IS NULL OR pi.eff_dt <= SYSTIMESTAMP)
          AND (pi.exp_dt IS NULL OR pi.exp_dt > SYSTIMESTAMP)
    )
    WHERE rn = 1
),
/* Existing duplicate physical rows inside a grading roster. */
roster_row_detail AS (
    SELECT DISTINCT
        tr.subterm_code,
        tr.subterm_name,
        tr.activity_offering_id,
        tr.roster_id,
        tr.roster_name,
        tr.roster_type,
        rr.ref_id AS person_id,
        COALESCE(
            CASE
                WHEN REGEXP_LIKE(TRIM(cr.pers_id), '^[0-9]{8}$')
                THEN TRIM(cr.pers_id)
            END,
            pei.eagle_id,
            CASE
                WHEN REGEXP_LIKE(TRIM(rr.ref_id), '^[0-9]{8}$')
                THEN TRIM(rr.ref_id)
            END,
            CASE
                WHEN REGEXP_LIKE(TRIM(rr.identifier), '^[0-9]{8}$')
                THEN TRIM(rr.identifier)
            END,
            rr.ref_id
        ) AS student_id,
        rr.id AS source_row_id,
        rr.roster_row_state AS source_state
    FROM term_rosters tr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = tr.roster_id
    LEFT JOIN {{SCHEMA}}.ksen_course_reg_reg cr
      ON cr.id = rr.ref_id
    LEFT JOIN person_eagle_ids pei
      ON pei.pers_id = cr.pers_id
    WHERE rr.ref_id IS NOT NULL
      AND (
            (
                (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
                AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
            )
            OR EXISTS (
                SELECT 1
                FROM {{SCHEMA}}.ksen_roster_r res
                WHERE res.roster_row_id = rr.id
                  AND (res.eff_dt IS NULL OR res.eff_dt <= SYSTIMESTAMP)
                  AND (res.exp_dt IS NULL OR res.exp_dt > SYSTIMESTAMP)
            )
      )
),
roster_row_duplicates AS (
    SELECT
        'ROSTER ROW' AS duplicate_source,
        subterm_code,
        subterm_name,
        activity_offering_id,
        roster_id,
        roster_name,
        roster_type,
        student_id,
        MIN(person_id) AS person_id,
        COUNT(DISTINCT source_row_id) AS row_count,
        LISTAGG(source_row_id, ', ')
            WITHIN GROUP (ORDER BY source_row_id) AS source_row_ids,
        LISTAGG(DISTINCT source_state, ', ')
            WITHIN GROUP (ORDER BY source_state) AS source_states,
        CAST(NULL AS VARCHAR2(4000)) AS grade_values
    FROM roster_row_detail
    GROUP BY
        subterm_code,
        subterm_name,
        activity_offering_id,
        roster_id,
        roster_name,
        roster_type,
        student_id
    HAVING COUNT(DISTINCT source_row_id) > 1
),
/*
Detect the special grading-page defect where the same Eagle ID/course/section
has both a withdrawal and a non-withdrawal academic-course record.
This is the condition present for 28576800 in PSYC2245 01.
*/
active_course_records AS (
    SELECT
        a.cd AS subterm_code,
        a.name AS subterm_name,
        sc.term_id,
        TRIM(sc.pers_id) AS student_id,
        UPPER(TRIM(sc.course_cd)) AS course_cd,
        UPPER(TRIM(sc.act_cd)) AS act_cd,
        sc.id AS source_row_id,
        sc.stu_course_state AS source_state,
        COALESCE(
            NULLIF(TRIM(sc.assigned_grade_value), ''),
            NULLIF(TRIM(sc.administrative_grade_value), ''),
            NULLIF(TRIM(sc.calculated_grade_value), '')
        ) AS grade_value
    FROM {{SCHEMA}}.kscr_ar_stu_course sc
    JOIN selected_atps a
      ON a.id = sc.term_id
    WHERE sc.pers_id IS NOT NULL
      AND sc.course_cd IS NOT NULL
      AND (sc.eff_dt IS NULL OR sc.eff_dt <= SYSTIMESTAMP)
      AND (sc.exp_dt IS NULL OR sc.exp_dt > SYSTIMESTAMP)
),
withdrawal_conflict_keys AS (
    SELECT
        subterm_code,
        subterm_name,
        term_id,
        student_id,
        course_cd,
        act_cd,
        COUNT(DISTINCT source_row_id) AS row_count,
        LISTAGG(source_row_id, ', ')
            WITHIN GROUP (ORDER BY source_row_id) AS source_row_ids,
        LISTAGG(DISTINCT source_state, ', ')
            WITHIN GROUP (ORDER BY source_state) AS source_states,
        LISTAGG(DISTINCT NVL(grade_value, '[blank]'), ', ')
            WITHIN GROUP (ORDER BY NVL(grade_value, '[blank]')) AS grade_values
    FROM active_course_records
    GROUP BY
        subterm_code,
        subterm_name,
        term_id,
        student_id,
        course_cd,
        act_cd
    HAVING COUNT(DISTINCT source_row_id) > 1
       AND SUM(CASE WHEN UPPER(grade_value) = 'W' THEN 1 ELSE 0 END) > 0
       AND SUM(CASE WHEN grade_value IS NOT NULL
                      AND UPPER(grade_value) <> 'W'
                    THEN 1 ELSE 0 END) > 0
),
withdrawal_conflicts AS (
    SELECT
        'WITHDRAWAL + GRADE' AS duplicate_source,
        w.subterm_code,
        w.subterm_name,
        tr.activity_offering_id,
        tr.roster_id,
        COALESCE(
            tr.roster_name,
            w.course_cd ||
                CASE WHEN w.act_cd IS NOT NULL THEN ' ' || w.act_cd END
        ) AS roster_name,
        tr.roster_type,
        w.student_id,
        CAST(NULL AS VARCHAR2(255)) AS person_id,
        w.row_count,
        w.source_row_ids,
        w.source_states,
        w.grade_values
    FROM withdrawal_conflict_keys w
    LEFT JOIN term_rosters tr
      ON tr.atp_id = w.term_id
     AND UPPER(TRIM(tr.roster_name)) =
         w.course_cd ||
         CASE WHEN w.act_cd IS NOT NULL THEN ' ' || w.act_cd END
),
/*
When the same student/course is identified by both checks, keep the more
informative WITHDRAWAL + GRADE row and suppress the generic ROSTER ROW row.
*/
roster_row_duplicates_filtered AS (
    SELECT rrd.*
    FROM roster_row_duplicates rrd
    WHERE NOT EXISTS (
        SELECT 1
        FROM withdrawal_conflicts wc
        WHERE wc.student_id = rrd.student_id
          AND wc.subterm_code = rrd.subterm_code
          AND (
                wc.roster_id = rrd.roster_id
                OR (
                    wc.roster_id IS NULL
                    AND UPPER(TRIM(wc.roster_name)) =
                        UPPER(TRIM(rrd.roster_name))
                )
          )
    )
)
SELECT
    duplicate_source,
    subterm_code,
    subterm_name,
    activity_offering_id,
    roster_id,
    roster_name,
    roster_type,
    student_id,
    person_id,
    row_count,
    source_states AS roster_row_states,
    grade_values,
    source_row_ids AS roster_row_ids
FROM (
    SELECT * FROM roster_row_duplicates_filtered
    UNION ALL
    SELECT * FROM withdrawal_conflicts
)
ORDER BY
    subterm_code,
    roster_name,
    student_id,
    duplicate_source
FETCH FIRST 5000 ROWS ONLY
