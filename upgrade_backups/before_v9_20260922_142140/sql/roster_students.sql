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
    SELECT a.id
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
selected_parent_atp AS (
    SELECT a.id
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
),
target_roster AS (
    SELECT
        r.id AS roster_id,
        r.roster_state
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a
      ON a.id = r.atp_id
    WHERE r.id = :roster_id
      AND (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
      AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
      AND r.roster_state IN (
          'kuali.grading.roster.state.submitted',
          'kuali.grading.roster.state.partial.submitted',
          'kuali.grading.roster.state.notstarted'
      )
),
preferred_person_name AS (
    SELECT
        pers_id,
        first_name,
        middle_name,
        last_name,
        composite_name
    FROM (
        SELECT
            pn.pers_id,
            pn.first_name,
            pn.middle_name,
            pn.last_name,
            pn.composite_name,
            ROW_NUMBER() OVER (
                PARTITION BY pn.pers_id
                ORDER BY
                    CASE
                        WHEN pn.pers_name_state =
                             'kuali.person.person.name.state.active'
                        THEN 0
                        ELSE 1
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
),
current_result_candidates AS (
    SELECT
        res.roster_row_id,
        res.r_value_id AS grade_value,
        ROW_NUMBER() OVER (
            PARTITION BY res.roster_row_id
            ORDER BY
                CASE
                    WHEN rc.roster_column_defn_id =
                         'roster.colum.definition.law.final.grade'
                    THEN 0
                    WHEN rc.roster_column_defn_id NOT IN (
                        'roster.colum.definition.law.blind.grade',
                        'roster.colum.definition.law.participation.grade',
                        'roster.colum.definition.law.final.grade'
                    )
                    THEN 1
                    WHEN rc.roster_column_defn_id =
                         'roster.colum.definition.law.participation.grade'
                    THEN 2
                    WHEN rc.roster_column_defn_id =
                         'roster.colum.definition.law.blind.grade'
                    THEN 3
                    ELSE 4
                END,
                res.updatetime DESC NULLS LAST,
                res.eff_dt DESC NULLS LAST,
                res.id
        ) AS rn
    FROM target_roster tr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = tr.roster_id
    JOIN {{SCHEMA}}.ksen_roster_r res
      ON res.roster_row_id = rr.id
    LEFT JOIN {{SCHEMA}}.ksen_roster_column rc
      ON rc.id = res.roster_column_id
    WHERE res.r_value_id IS NOT NULL
      AND (
             res.roster_r_state IS NULL
          OR res.roster_r_state <>
             'kuali.grading.roster.result.state.superseded'
      )
      AND (res.eff_dt IS NULL OR res.eff_dt <= SYSTIMESTAMP)
      AND (res.exp_dt IS NULL OR res.exp_dt > SYSTIMESTAMP)
),
current_results AS (
    SELECT
        roster_row_id,
        grade_value
    FROM current_result_candidates
    WHERE rn = 1
),
student_rows AS (
    SELECT
        tr.roster_id,
        tr.roster_state,
        rr.id AS roster_row_id,
        rr.ref_id AS registration_id,
        rr.roster_row_state,
        reg.pers_id AS student_id,
        COALESCE(
            pn.composite_name,
            NULLIF(
                TRIM(
                    pn.first_name
                    || CASE
                           WHEN pn.first_name IS NOT NULL
                            AND pn.last_name IS NOT NULL
                           THEN ' '
                       END
                    || pn.last_name
                ),
                ''
            ),
            p.name,
            reg.pers_id,
            rr.identifier,
            rr.ref_id
        ) AS student_name,
        pn.last_name,
        cr.grade_value,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM {{SCHEMA}}.ksen_prog_status ps
                WHERE ps.pers_id = reg.pers_id
                  AND (
                         ps.prog_status_state =
                             'kuali.programenrollment.programstatus.state.active'
                      OR (
                             ps.prog_status_state =
                                 'kuali.programenrollment.programstatus.state.eligible'
                         AND UPPER(ps.prog_status_type) LIKE
                             '%GRADUATE.DISCIPLINE%'
                      )
                  )
                  AND (ps.eff_dt IS NULL OR
                       ps.eff_dt <= SYSTIMESTAMP)
                  AND (ps.exp_dt IS NULL OR
                       ps.exp_dt > SYSTIMESTAMP)
                  AND ps.exped_compltn_term_id IN (
                      SELECT spa.id
                      FROM selected_parent_atp spa
                  )
            )
            THEN 'Y'
            ELSE 'N'
        END AS expected_graduate_ind,
        COUNT(*) OVER (
            PARTITION BY
                tr.roster_id,
                COALESCE(reg.pers_id, rr.id)
        ) AS student_row_count
    FROM target_roster tr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = tr.roster_id
     AND rr.roster_row_state =
         'kuali.grading.roster.row.state.active'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_course_reg_reg reg
      ON reg.id = rr.ref_id
    LEFT JOIN {{SCHEMA}}.ksen_pers p
      ON p.id = reg.pers_id
    LEFT JOIN preferred_person_name pn
      ON pn.pers_id = reg.pers_id
    LEFT JOIN current_results cr
      ON cr.roster_row_id = rr.id
)
SELECT
    roster_id,
    roster_row_id,
    registration_id,
    student_id,
    student_name,
    roster_row_state,
    CASE
        WHEN roster_state =
             'kuali.grading.roster.state.submitted'
        THEN 'Y'
        WHEN roster_state =
             'kuali.grading.roster.state.partial.submitted'
         AND grade_value IS NOT NULL
        THEN 'Y'
        ELSE 'N'
    END AS graded_ind,
    grade_value,
    expected_graduate_ind,
    CASE WHEN student_row_count > 1 THEN 'Y' ELSE 'N' END
        AS duplicate_student_ind
FROM student_rows
ORDER BY
    last_name NULLS LAST,
    student_name,
    student_id,
    roster_row_id
FETCH FIRST 1000 ROWS ONLY
