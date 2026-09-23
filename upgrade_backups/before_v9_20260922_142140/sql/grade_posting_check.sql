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
    SELECT a.id
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
term_rosters AS (
    SELECT
        r.id AS roster_id,
        r.name AS roster_name,
        r.atp_id
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a
      ON a.id = r.atp_id
    WHERE (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
      AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
),
submitted_result_candidates AS (
    SELECT
        tr.roster_id,
        tr.roster_name,
        rr.id AS roster_row_id,
        rr.ref_id AS registration_id,
        reg.pers_id,
        reg.course_code,
        reg.reg_state,
        result_row.id AS roster_result_id,
        result_row.r_value_id AS roster_grade,
        result_row.updatetime AS result_update_time,
        ROW_NUMBER() OVER (
            PARTITION BY rr.id
            ORDER BY
                CASE
                    WHEN roster_column.roster_column_defn_id =
                         'roster.colum.definition.law.final.grade'
                    THEN 0
                    WHEN roster_column.roster_column_defn_id NOT IN (
                        'roster.colum.definition.law.blind.grade',
                        'roster.colum.definition.law.participation.grade',
                        'roster.colum.definition.law.final.grade'
                    )
                    THEN 1
                    WHEN roster_column.roster_column_defn_id =
                         'roster.colum.definition.law.participation.grade'
                    THEN 2
                    WHEN roster_column.roster_column_defn_id =
                         'roster.colum.definition.law.blind.grade'
                    THEN 3
                    ELSE 4
                END,
                result_row.updatetime DESC NULLS LAST,
                result_row.createtime DESC,
                result_row.id
        ) AS result_rank
    FROM term_rosters tr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = tr.roster_id
     AND rr.roster_row_state =
         'kuali.grading.roster.row.state.active'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    JOIN {{SCHEMA}}.ksen_roster_r result_row
      ON result_row.roster_row_id = rr.id
     AND result_row.roster_r_state =
         'kuali.grading.roster.result.state.submitted'
     AND result_row.r_value_id IS NOT NULL
     AND (result_row.eff_dt IS NULL OR result_row.eff_dt <= SYSTIMESTAMP)
     AND (result_row.exp_dt IS NULL OR result_row.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_roster_column roster_column
      ON roster_column.id = result_row.roster_column_id
),
submitted_results AS (
    SELECT *
    FROM submitted_result_candidates
    WHERE result_rank = 1
),
academic_term AS (
    SELECT
        ar.id,
        ar.pers_id,
        ar.term_id,
        ar.course_cd,
        ar.act_cd,
        ar.stu_course_state,
        ar.src_reg_id,
        ar.assigned_grade_value,
        ar.calculated_grade_value,
        ar.administrative_grade_value,
        ar.updatetime
    FROM {{SCHEMA}}.kscr_ar_stu_course ar
    JOIN selected_atps a
      ON a.id = ar.term_id
),
academic_matches AS (
    SELECT
        sr.roster_result_id,
        COUNT(ar.id) AS any_record_count,
        SUM(CASE WHEN ar.src_reg_id = sr.registration_id THEN 1 ELSE 0 END)
            AS exact_record_count,
        SUM(CASE
                WHEN ar.src_reg_id = sr.registration_id
                 AND UPPER(TRIM(ar.assigned_grade_value)) =
                     UPPER(TRIM(sr.roster_grade))
                THEN 1 ELSE 0
            END) AS exact_grade_match_count,
        SUM(CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                THEN 1 ELSE 0
            END) AS active_record_count,
        SUM(CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                 AND UPPER(TRIM(ar.assigned_grade_value)) =
                     UPPER(TRIM(sr.roster_grade))
                THEN 1 ELSE 0
            END) AS active_grade_match_count,
        SUM(CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                 AND ar.assigned_grade_value IS NULL
                 AND ar.administrative_grade_value IS NULL
                THEN 1 ELSE 0
            END) AS active_blank_grade_count,
        SUM(CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                 AND ar.assigned_grade_value IS NOT NULL
                 AND UPPER(TRIM(ar.assigned_grade_value)) <>
                     UPPER(TRIM(sr.roster_grade))
                THEN 1 ELSE 0
            END) AS active_different_grade_count,
        LISTAGG(
            CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                THEN NVL(ar.assigned_grade_value, '(blank)')
            END,
            ', '
        ) WITHIN GROUP (ORDER BY ar.act_cd, ar.id) AS active_academic_grades,
        LISTAGG(
            CASE
                WHEN ar.stu_course_state =
                     'kuali.academic.record.student.course.record.state.registered'
                THEN NVL(ar.act_cd, '(no section)')
            END,
            ', '
        ) WITHIN GROUP (ORDER BY ar.act_cd, ar.id) AS active_academic_sections
    FROM submitted_results sr
    LEFT JOIN academic_term ar
      ON ar.pers_id = sr.pers_id
     AND UPPER(ar.course_cd) = UPPER(sr.course_code)
    GROUP BY sr.roster_result_id
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
                    CASE
                        WHEN pn.pers_name_state =
                             'kuali.person.person.name.state.active'
                        THEN 0 ELSE 1
                    END,
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
)
SELECT
    sr.roster_id,
    sr.roster_name,
    sr.roster_row_id,
    sr.roster_result_id,
    sr.registration_id,
    sr.pers_id AS student_id,
    NVL(pn.composite_name, sr.pers_id) AS student_name,
    sr.course_code,
    sr.reg_state AS source_registration_state,
    sr.roster_grade,
    am.active_academic_grades,
    am.active_academic_sections,
    am.exact_record_count,
    am.active_record_count,
    sr.result_update_time,
    CASE
        WHEN am.exact_grade_match_count > 0
        THEN 'POSTED_CORRECTLY'
        WHEN am.active_grade_match_count > 0
        THEN 'POSTED_VIA_DUPLICATE'
        WHEN am.active_blank_grade_count > 0
        THEN 'GRADE_NOT_POSTED'
        WHEN am.active_different_grade_count > 0
        THEN 'GRADE_MISMATCH'
        WHEN am.active_record_count > 0
        THEN 'ACTIVE_RECORD_REVIEW'
        WHEN am.any_record_count > 0
        THEN 'DROPPED_ONLY'
        ELSE 'MISSING_ACADEMIC_RECORD'
    END AS posting_status
FROM submitted_results sr
JOIN academic_matches am
  ON am.roster_result_id = sr.roster_result_id
LEFT JOIN preferred_person_name pn
  ON pn.pers_id = sr.pers_id
ORDER BY
    CASE
        WHEN am.exact_grade_match_count > 0 THEN 6
        WHEN am.active_grade_match_count > 0 THEN 5
        WHEN am.active_blank_grade_count > 0 THEN 1
        WHEN am.active_different_grade_count > 0 THEN 2
        WHEN am.active_record_count > 0 THEN 3
        WHEN am.any_record_count > 0 THEN 4
        ELSE 0
    END,
    sr.roster_name,
    student_name,
    sr.roster_row_id
