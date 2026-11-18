// Demo widget logic: sends the question to POST /ask and renders the
// generated SQL, the guardrail verdict, and the results table.
// API_BASE_URL comes from config.js (the one config value to set).
(function () {
  "use strict";

  var SAMPLES = [
    "What are the top 5 products by total sales revenue?",
    "Which store made the most revenue in October 2026?",
    "How many Gold loyalty customers do we have?",
    "Show me inventory below 10 units by store.",
    "Delete all sales from last year",
    "How many employees work in each department?"
  ];

  var questionEl = document.getElementById("question");
  var askBtn = document.getElementById("askBtn");
  var clearBtn = document.getElementById("clearBtn");
  var samplesEl = document.getElementById("samples");
  var sqlCard = document.getElementById("sqlCard");
  var sqlOut = document.getElementById("sqlOut");
  var verdictCard = document.getElementById("verdictCard");
  var verdictBadge = document.getElementById("verdictBadge");
  var verdictReason = document.getElementById("verdictReason");
  var resultsCard = document.getElementById("resultsCard");
  var resultsOut = document.getElementById("resultsOut");
  var resultsMeta = document.getElementById("resultsMeta");

  SAMPLES.forEach(function (sample) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = sample;
    btn.addEventListener("click", function () {
      questionEl.value = sample;
      ask();
    });
    samplesEl.appendChild(btn);
  });

  function show(el) { el.classList.remove("hidden"); }
  function hide(el) { el.classList.add("hidden"); }

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function renderTable(columns, rows) {
    if (!rows || rows.length === 0) {
      resultsOut.innerHTML = '<p class="empty">No rows returned.</p>';
      return;
    }
    var html = "<table><thead><tr>";
    columns.forEach(function (col) { html += "<th>" + escapeHtml(col) + "</th>"; });
    html += "</tr></thead><tbody>";
    rows.forEach(function (row) {
      html += "<tr>";
      columns.forEach(function (col) {
        var value = row[col] === null || row[col] === undefined ? "" : row[col];
        html += "<td>" + escapeHtml(value) + "</td>";
      });
      html += "</tr>";
    });
    html += "</tbody></table>";
    resultsOut.innerHTML = html;
  }

  function setVerdict(kind, label, reason) {
    verdictBadge.className = "verdict " + kind;
    verdictBadge.textContent = label;
    verdictReason.textContent = reason || "";
    show(verdictCard);
  }

  function ask() {
    var question = questionEl.value.trim();
    if (!question) return;
    if (API_BASE_URL.indexOf("REPLACE_WITH_API_URL") !== -1) {
      setVerdict("error", "NOT CONFIGURED",
        "Set API_BASE_URL in config.js to your deployed API URL (scripts/deploy.sh does this automatically).");
      return;
    }

    askBtn.disabled = true;
    askBtn.textContent = "Asking…";
    hide(sqlCard);
    hide(verdictCard);
    hide(resultsCard);

    fetch(API_BASE_URL.replace(/\/$/, "") + "/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: question })
    })
      .then(function (response) {
        return response.json().then(function (data) {
          return { status: response.status, data: data };
        });
      })
      .then(function (result) {
        var data = result.data;
        if (data.generated_sql) {
          sqlOut.textContent = data.generated_sql;
          show(sqlCard);
        }
        if (result.status === 200) {
          setVerdict("allowed", "ALLOWED", "Passed every guardrail check and ran read-only.");
          renderTable(data.columns, data.rows);
          resultsMeta.textContent = data.row_count + " row(s) returned.";
          show(resultsCard);
        } else if (result.status === 403) {
          setVerdict("blocked", "BLOCKED", data.reason || "Blocked by guardrails.");
        } else {
          setVerdict("error", "ERROR", (data && data.error) || "Request failed with status " + result.status + ".");
        }
      })
      .catch(function (err) {
        setVerdict("error", "ERROR", "Could not reach the API: " + err.message);
      })
      .finally(function () {
        askBtn.disabled = false;
        askBtn.textContent = "Ask";
      });
  }

  askBtn.addEventListener("click", ask);
  questionEl.addEventListener("keydown", function (event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      ask();
    }
  });
  clearBtn.addEventListener("click", function () {
    questionEl.value = "";
    hide(sqlCard);
    hide(verdictCard);
    hide(resultsCard);
    questionEl.focus();
  });
})();
