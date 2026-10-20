(() => {
  "use strict";

  const state = {
    rows: [], filtered: [], loaded: false, loading: false, error: "",
    expanded: new Set(), students: new Map(), studentErrors: new Map(), studentLoading: new Set()
  };
  const body = document.getElementById("population-body");
  if (!body) return;
  const esc = value => String(value ?? "").replace(/[&<>'"]/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[ch]));
  const num = value => Number(value || 0);
  const norm = value => String(value ?? "").toLowerCase().trim();
  const key = row => `${row.activity_offering_id}::${row.roster_type}`;
  const isDiscrepancy = row => row.discrepancy_type !== "MATCH";
  const label = value => ({
    MATCH:"Match", REGISTRATION_GREATER:"Registration greater", GRADING_GREATER:"Grading greater",
    COUNTS_MATCH_STUDENTS_DIFFER:"Equal counts, students differ", NO_CURRENT_GRADING_ROSTER:"No current grading roster",
    MULTIPLE_CURRENT_ROSTERS:"Multiple current rosters", ACTIVE_STUDENTS_ON_ABANDONED_ROSTER:"Active students on abandoned roster",
    MIXED_DISCREPANCY:"Mixed discrepancy", MISSING_FROM_GRADING:"Missing from grading",
    NOT_ACTIVE_IN_REGISTRATION:"Not active in registration", MATCHED:"Matched"
  })[value] || value || "—";

  function setText(id, value) { const el = document.getElementById(id); if (el) el.textContent = value; }
  function filterRows() {
    const search = norm(document.getElementById("population-search").value);
    const type = document.getElementById("population-type-filter").value;
    const rosterType = document.getElementById("population-roster-type-filter").value;
    state.filtered = state.rows.filter(row => {
      if (type === "ANY" && !isDiscrepancy(row)) return false;
      if (type === "STRANDED" && num(row.stranded_active_student_count) === 0) return false;
      if (type && !["ANY","STRANDED"].includes(type) && row.discrepancy_type !== type) return false;
      if (rosterType && row.roster_type !== rosterType) return false;
      if (search && !norm([row.course_code,row.course_name,row.subterm_code,row.subterm_name,row.activity_offering_id,row.current_roster_ids,row.roster_type,row.discrepancy_type].join(" ")).includes(search)) return false;
      return true;
    });
  }
  function updateMetrics() {
    const rows = state.filtered;
    setText("population-reviewed", state.loaded ? rows.length : "—");
    setText("population-discrepancies", state.loaded ? rows.filter(isDiscrepancy).length : "—");
    setText("population-reg-greater", state.loaded ? rows.filter(r => r.discrepancy_type === "REGISTRATION_GREATER").length : "—");
    setText("population-grade-greater", state.loaded ? rows.filter(r => r.discrepancy_type === "GRADING_GREATER").length : "—");
    setText("population-different", state.loaded ? rows.filter(r => r.discrepancy_type === "COUNTS_MATCH_STUDENTS_DIFFER").length : "—");
    setText("population-no-roster", state.loaded ? rows.filter(r => r.discrepancy_type === "NO_CURRENT_GRADING_ROSTER").length : "—");
    setText("population-multiple", state.loaded ? rows.filter(r => r.discrepancy_type === "MULTIPLE_CURRENT_ROSTERS" || (r.discrepancy_type === "MIXED_DISCREPANCY" && num(r.current_roster_count) > 1)).length : "—");
    setText("population-stranded", state.loaded ? rows.reduce((t,r) => t + num(r.stranded_active_student_count), 0) : "—");
    setText("population-missing-students", state.loaded ? rows.reduce((t,r) => t + num(r.missing_from_grading_count), 0) : "—");
    setText("population-not-active-students", state.loaded ? rows.reduce((t,r) => t + num(r.not_active_registration_count), 0) : "—");
    setText("population-visible-count", state.loaded ? `${rows.length} visible comparison${rows.length === 1 ? "" : "s"}` : "");
  }
  function studentMarkup(row) {
    const rowKey = key(row);
    if (state.studentLoading.has(rowKey)) return '<p class="roster-loading">Loading student comparison…</p>';
    if (state.studentErrors.has(rowKey)) return `<div class="error">Student comparison failed: ${esc(state.studentErrors.get(rowKey))}</div>`;
    if (!state.students.has(rowKey)) return '<p class="muted">Student details have not been loaded.</p>';
    const students = state.students.get(rowKey);
    if (!students.length) return '<p class="muted">No students were returned for this comparison.</p>';
    return `<div class="roster-student-heading"><h3>Student comparison</h3><span class="result-count">${students.length} student${students.length === 1 ? "" : "s"}</span></div>
      <div class="table-wrap roster-student-table-wrap"><table class="roster-student-table"><thead><tr><th>Student</th><th>Eagle ID</th><th>Registration ID/state</th><th>On registration</th><th>On grading</th><th>Roster/row</th><th>Result</th><th>Historical location</th></tr></thead><tbody>${students.map(s => `<tr>
        <td>${esc(s.student_name)}</td><td class="technical">${esc(s.student_id)}</td>
        <td><span class="technical">${esc(s.registration_id || "—")}</span><br>${esc(s.registration_state || "—")}</td>
        <td>${s.on_registration_roster === "Y" ? "Yes" : "No"}</td><td>${s.on_grading_roster === "Y" ? "Yes" : "No"}</td>
        <td><span class="technical">${esc(s.roster_id || "—")}</span><br><span class="technical">${esc(s.roster_row_id || "—")}</span><br>${esc(s.roster_row_state || "—")}</td>
        <td class="${s.student_discrepancy_type === "MATCHED" ? "posting-good" : "posting-exception"}">${esc(label(s.student_discrepancy_type))}</td>
        <td><span class="technical">${esc(s.historical_roster_ids || "—")}</span><br>${esc(s.historical_roster_states || "")}${s.historical_row_states ? `<br>${esc(s.historical_row_states)}` : ""}</td>
      </tr>`).join("")}</tbody></table></div>`;
  }
  function rowMarkup(row) {
    const rowKey = key(row), expanded = state.expanded.has(rowKey);
    return `<tr class="data-row">
      <td>${esc(row.course_code || row.course_name || "Unnamed section")}<div class="technical">${esc(row.activity_offering_id)}</div></td>
      <td>${esc(row.subterm_name || row.subterm_code)}</td><td>${num(row.registration_student_count)}</td><td>${num(row.grading_student_count)}</td>
      <td class="${num(row.missing_from_grading_count) ? "posting-exception" : ""}">${num(row.missing_from_grading_count)}</td>
      <td class="${num(row.not_active_registration_count) ? "posting-exception" : ""}">${num(row.not_active_registration_count)}</td>
      <td>${num(row.matched_student_count)}</td><td>${num(row.current_roster_count)}<div class="technical">${esc(row.current_roster_ids || "—")}</div></td>
      <td>${num(row.abandoned_roster_count)}</td><td class="technical">${esc(row.roster_type)}</td>
      <td><span class="population-status ${row.review_status === "OK" ? "population-ok" : row.review_status === "HIGH" ? "population-high" : "population-review"}">${esc(label(row.discrepancy_type))}</span>${num(row.stranded_active_student_count) ? `<div class="issue-pill">${num(row.stranded_active_student_count)} stranded active</div>` : ""}</td>
      <td><button type="button" class="button-secondary population-detail-toggle" data-key="${esc(rowKey)}">${expanded ? "Close" : "Open"}</button></td>
    </tr>${expanded ? `<tr class="detail-row"><td colspan="12"><div class="detail-grid">
      <div><strong>Activity offering ID</strong><div class="technical">${esc(row.activity_offering_id)}</div></div><div><strong>Current roster state(s)</strong><div class="technical">${esc(row.current_roster_states || "None")}</div></div>
      <div><strong>Current roster count</strong><div>${num(row.current_roster_count)}</div></div><div><strong>Abandoned roster count</strong><div>${num(row.abandoned_roster_count)}</div></div>
      <div><strong>Review status</strong><div>${esc(row.review_status)}</div></div><div><strong>Registration source</strong><div>${esc(row.registration_source)}</div></div>
    </div>${studentMarkup(row)}</td></tr>` : ""}`;
  }
  function updateStatus() {
    const button = document.getElementById("run-population-check"), status = document.getElementById("population-check-status");
    button.disabled = state.loading; button.textContent = state.loading ? "Comparing rosters…" : state.loaded ? "Run roster population checker again" : "Run roster population checker";
    if (state.error) { status.className = "error posting-check-status"; status.textContent = `Roster population check failed: ${state.error}`; }
    else if (state.loading) { status.className = "muted posting-check-status"; status.textContent = "Comparing exact-section active registrations with current grading workflows…"; }
    else if (state.loaded) { status.className = "posting-check-status"; status.textContent = `${state.rows.length} section/workflow comparisons loaded; ${state.rows.filter(isDiscrepancy).length} require review.`; }
    else { status.className = "muted posting-check-status"; status.textContent = "Runs on demand. Student details load only when a section is opened."; }
  }
  function render() {
    filterRows(); updateMetrics();
    if (!state.loaded && !state.loading) return;
    body.innerHTML = state.filtered.length ? state.filtered.map(rowMarkup).join("") : '<tr><td colspan="12" class="empty-state">No comparisons match the current filters.</td></tr>';
  }
  async function runCheck() {
    if (state.loading) return; state.loading = true; state.error = ""; updateStatus();
    body.innerHTML = '<tr><td colspan="12" class="empty-state">Loading roster comparisons…</td></tr>';
    try {
      const response = await fetch(`/api/roster-population?term_code=${encodeURIComponent(window.dashboardConfig.selectedTerm)}`, {headers:{Accept:"application/json"}});
      const payload = await response.json().catch(() => ({})); if (!response.ok) throw new Error(payload.detail || `Request failed (${response.status})`);
      state.rows = Array.isArray(payload.results) ? payload.results : []; state.loaded = true; state.expanded.clear(); state.students.clear();
      const select = document.getElementById("population-roster-type-filter"), current = select.value;
      select.innerHTML = '<option value="">All roster types</option>' + [...new Set(state.rows.map(r => r.roster_type).filter(Boolean))].sort().map(v => `<option value="${esc(v)}">${esc(v)}</option>`).join(""); select.value = current;
    } catch (error) { state.error = error.message || "Unknown error"; state.loaded = false; }
    finally { state.loading = false; updateStatus(); render(); }
  }
  async function loadStudents(row) {
    const rowKey = key(row); if (state.students.has(rowKey) || state.studentLoading.has(rowKey)) return;
    state.studentLoading.add(rowKey); render();
    try {
      const params = new URLSearchParams({term_code:window.dashboardConfig.selectedTerm,activity_offering_id:row.activity_offering_id,roster_type:row.roster_type});
      const response = await fetch(`/api/roster-population/students?${params}`, {headers:{Accept:"application/json"}}), payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.detail || `Request failed (${response.status})`); state.students.set(rowKey, Array.isArray(payload.students) ? payload.students : []);
    } catch (error) { state.studentErrors.set(rowKey, error.message || "Unknown error"); }
    finally { state.studentLoading.delete(rowKey); render(); }
  }
  function csvEscape(value) { const s = String(value ?? "").replace(/\s+/g," ").trim(); return /[",\n]/.test(s) ? `"${s.replace(/"/g,'""')}"` : s; }
  function saveCsv(name, headers, rows) { const blob = new Blob([[headers,...rows].map(r => r.map(csvEscape).join(",")).join("\r\n")],{type:"text/csv;charset=utf-8"}), link=document.createElement("a"); link.href=URL.createObjectURL(blob); link.download=name; link.click(); URL.revokeObjectURL(link.href); }
  function downloadSections() {
    if (!state.loaded) return;
    const headers=["Subterm","Course","Roster name","Activity offering ID","Roster type","Registration students","Grading students","Missing from grading","Not active in registration","Matched","Current roster count","Current roster IDs","Current roster states","Abandoned roster count","Stranded active students","Discrepancy type","Review status","Registration source"];
    saveCsv(`registration_vs_grading_${window.dashboardConfig.selectedTerm}.csv`,headers,state.filtered.map(r=>[r.subterm_code,r.course_code,r.course_name,r.activity_offering_id,r.roster_type,r.registration_student_count,r.grading_student_count,r.missing_from_grading_count,r.not_active_registration_count,r.matched_student_count,r.current_roster_count,r.current_roster_ids,r.current_roster_states,r.abandoned_roster_count,r.stranded_active_student_count,r.discrepancy_type,r.review_status,r.registration_source]));
  }
  async function downloadStudents() {
    if (!state.loaded) return;
    const button=document.getElementById("download-population-students-csv"), original=button.textContent; button.disabled=true; button.textContent="Preparing CSV…";
    try {
      const response=await fetch(`/api/roster-population/student-export?term_code=${encodeURIComponent(window.dashboardConfig.selectedTerm)}`,{headers:{Accept:"application/json"}}),payload=await response.json().catch(()=>({}));
      if(!response.ok) throw new Error(payload.detail||`Request failed (${response.status})`);
      const allowed=new Set(state.filtered.filter(isDiscrepancy).map(key));
      const records=(Array.isArray(payload.results)?payload.results:[]).filter(s=>allowed.has(`${s.activity_offering_id}::${s.roster_type}`));
      const rows=records.map(s=>[s.subterm_code,s.course_code,s.activity_offering_id,s.roster_type,s.student_name,s.student_id,s.registration_id,s.registration_state,s.registration_eff_dt,s.registration_exp_dt,s.roster_id,s.roster_state,s.roster_row_id,s.roster_row_state,s.on_registration_roster,s.on_grading_roster,s.student_discrepancy_type,s.historical_roster_ids,s.historical_roster_states,s.historical_row_states]);
      saveCsv(`registration_vs_grading_students_${window.dashboardConfig.selectedTerm}.csv`,["Subterm","Course","Activity offering ID","Roster type","Student","Eagle ID","Registration ID","Registration state","Registration effective","Registration expiration","Roster ID","Roster state","Roster row ID","Roster row state","On registration roster","On grading roster","Discrepancy","Historical roster IDs","Historical roster states","Historical row states"],rows);
    } catch(error) { window.alert(`Student export failed: ${error.message||"Unknown error"}`); }
    finally { button.disabled=false; button.textContent=original; }
  }
  async function downloadAudit() {
    const button=document.getElementById("download-roster-audit-csv"), original=button.textContent; button.disabled=true; button.textContent="Loading audit…";
    try {
      const response=await fetch(`/api/roster-replacement-audit?term_code=${encodeURIComponent(window.dashboardConfig.selectedTerm)}`,{headers:{Accept:"application/json"}}),payload=await response.json().catch(()=>({})); if(!response.ok) throw new Error(payload.detail||`Request failed (${response.status})`);
      const allowed=new Set(state.filtered.map(r=>r.activity_offering_id)), records=(payload.results||[]).filter(r=>!state.loaded||allowed.has(r.activity_offering_id));
      saveCsv(`roster_replacement_audit_${window.dashboardConfig.selectedTerm}.csv`,["Subterm","Activity offering ID","Roster name","Roster type","Historical roster ID","Historical roster state","Historical row ID","Historical row state","Registration ID","Student","Eagle ID","Course","Registration state","Reason"],records.map(r=>[r.subterm_code,r.activity_offering_id,r.roster_name,r.roster_type,r.historical_roster_id,r.historical_roster_state,r.historical_roster_row_id,r.historical_roster_row_state,r.registration_id,r.student_name,r.student_id,r.course_code,r.registration_state,r.audit_reason]));
    } catch(error) { window.alert(`Audit export failed: ${error.message||"Unknown error"}`); }
    finally { button.disabled=false; button.textContent=original; }
  }

  document.getElementById("run-population-check").addEventListener("click",runCheck);
  ["population-search","population-type-filter","population-roster-type-filter"].forEach(id=>document.getElementById(id).addEventListener("input",render));
  document.getElementById("clear-population-filters").addEventListener("click",()=>{["population-search","population-type-filter","population-roster-type-filter"].forEach(id=>document.getElementById(id).value="");render();});
  document.getElementById("download-population-csv").addEventListener("click",downloadSections);
  document.getElementById("download-population-students-csv").addEventListener("click",downloadStudents);
  document.getElementById("download-roster-audit-csv").addEventListener("click",downloadAudit);
  body.addEventListener("click",event=>{const button=event.target.closest(".population-detail-toggle");if(!button)return;const row=state.rows.find(r=>key(r)===button.dataset.key);if(!row)return;if(state.expanded.has(button.dataset.key))state.expanded.delete(button.dataset.key);else{state.expanded.add(button.dataset.key);loadStudents(row);}render();});
  document.querySelectorAll(".population-metric[data-population-type]").forEach(button=>button.addEventListener("click",()=>{document.getElementById("population-type-filter").value=button.dataset.populationType||"";render();}));
  updateStatus(); updateMetrics();
})();
