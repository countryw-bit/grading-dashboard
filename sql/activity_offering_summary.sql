WITH term_parameters AS (
    SELECT
        :term_code AS selected_term,
        CASE
            WHEN :term_code LIKE '%SUMM'
                THEN SUBSTR(:term_code, 1, LENGTH(:term_code) - 1)
            ELSE :term_code
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
    WHERE a.cd = p.selected_term
       OR a.cd LIKE p.term_prefix || '%'
),
term_rosters AS (
    SELECT
        r.id AS roster_id,
        r.ref_id AS activity_offering_id,
        r.name AS course_name,
        r.roster_type,
        r.roster_state,
        r.due_dt,
        a.cd AS subterm_code,
        a.name AS subterm_name
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a
      ON a.id = r.atp_id
    WHERE (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
      AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
      AND r.roster_state IN (
          'kuali.grading.roster.state.submitted',
          'kuali.grading.roster.state.partial.submitted',
          'kuali.grading.roster.state.notstarted'
      )
),
roster_counts AS (
    SELECT
        rr.roster_id,
        COUNT(DISTINCT rr.id) AS roster_size,
        COUNT(
            DISTINCT CASE
                WHEN res.roster_r_state =
                     'kuali.grading.roster.result.state.submitted'
                 AND (res.eff_dt IS NULL OR res.eff_dt <= SYSTIMESTAMP)
                 AND (res.exp_dt IS NULL OR res.exp_dt > SYSTIMESTAMP)
                THEN rr.id
            END
        ) AS graded_count
    FROM term_rosters tr
    JOIN {{SCHEMA}}.ksen_roster_row rr
      ON rr.roster_id = tr.roster_id
     AND rr.roster_row_state =
         'kuali.grading.roster.row.state.active'
     AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
     AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
    LEFT JOIN {{SCHEMA}}.ksen_roster_r res
      ON res.roster_row_id = rr.id
    GROUP BY rr.roster_id
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
preferred_university_email AS (
    SELECT
        person_id,
        email_address
    FROM (
        SELECT
            c.ref_id AS person_id,
            ca.addr AS email_address,
            ROW_NUMBER() OVER (
                PARTITION BY c.ref_id
                ORDER BY
                    c.eff_dt DESC NULLS LAST,
                    c.updatetime DESC NULLS LAST,
                    c.id
            ) AS rn
        FROM {{SCHEMA}}.ksen_contact c
        JOIN {{SCHEMA}}.ksen_contact_addr ca
          ON ca.id = c.addr_id
        WHERE c.contact_type =
              'kuali.contact.contact.type.email.university'
          AND c.contact_state =
              'kuali.contact.contact.state.active'
          AND ca.addr_type =
              'kuali.contact.address.type.email'
          AND ca.addr_state =
              'kuali.contact.address.state.active'
          AND ca.addr IS NOT NULL
          AND (c.eff_dt IS NULL OR c.eff_dt <= SYSTIMESTAMP)
          AND (c.exp_dt IS NULL OR c.exp_dt > SYSTIMESTAMP)
    )
    WHERE rn = 1
),
roster_instructor_detail AS (
    SELECT
        rg.roster_id,
        rg.grader_pers_id AS instructor_id,
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
            rg.grader_pers_id
        ) AS instructor_name,
        LOWER(e.email_address) AS instructor_email
    FROM {{SCHEMA}}.ksen_roster_grader_pers_ids rg
    JOIN term_rosters tr
      ON tr.roster_id = rg.roster_id
    JOIN {{SCHEMA}}.ksen_pers p
      ON p.id = rg.grader_pers_id
    LEFT JOIN preferred_person_name pn
      ON pn.pers_id = p.id
    LEFT JOIN preferred_university_email e
      ON e.person_id = p.id
),
roster_instructors AS (
    SELECT
        roster_id,
        LISTAGG(instructor_id, '; ')
            WITHIN GROUP (ORDER BY instructor_name, instructor_id)
            AS instructor_ids,
        LISTAGG(instructor_name, '; ')
            WITHIN GROUP (ORDER BY instructor_name, instructor_id)
            AS instructor_names,
        LISTAGG(instructor_email, '; ')
            WITHIN GROUP (ORDER BY instructor_name, instructor_id)
            AS instructor_emails,
        COUNT(*) AS instructor_count,
        SUM(CASE WHEN instructor_email IS NULL THEN 1 ELSE 0 END)
            AS instructors_missing_email
    FROM roster_instructor_detail
    GROUP BY roster_id
)
SELECT
    tr.activity_offering_id,
    tr.roster_id,
    tr.subterm_code,
    tr.subterm_name,
    tr.course_name,
    tr.roster_type,
    tr.roster_state,
    tr.due_dt,
    ri.instructor_ids AS grader_ids,
    ri.instructor_names,
    ri.instructor_emails,
    NVL(ri.instructor_count, 0) AS instructor_count,
    NVL(ri.instructors_missing_email, 0) AS instructors_missing_email,
    NVL(rc.roster_size, 0) AS roster_size,
    NVL(rc.graded_count, 0) AS graded_count,
    CASE
        WHEN tr.due_dt < SYSTIMESTAMP THEN 'Y'
        ELSE 'N'
    END AS is_overdue,
    CASE
        WHEN tr.roster_type IN (
            'kuali.grading.roster.type.blind',
            'kuali.grading.roster.type.participation',
            'kuali.grading.roster.type.final'
        )
        THEN 'LAW_BLIND'
        ELSE 'STANDARD'
    END AS grading_model,
    CASE
        WHEN tr.roster_state =
             'kuali.grading.roster.state.submitted'
        THEN 'SUBMITTED'
        WHEN tr.roster_state =
             'kuali.grading.roster.state.partial.submitted'
        THEN 'PARTIAL'
        ELSE 'NOT_STARTED'
    END AS overall_status
FROM term_rosters tr
LEFT JOIN roster_counts rc
  ON rc.roster_id = tr.roster_id
LEFT JOIN roster_instructors ri
  ON ri.roster_id = tr.roster_id
ORDER BY
    tr.subterm_code,
    tr.course_name,
    tr.roster_id
FETCH FIRST 10000 ROWS ONLY
