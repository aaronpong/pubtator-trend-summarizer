# Colorectal cancer research trends: Shiny dashboard
# Reads app_data.duckdb (exported from the Python notebook) and shows
# topic trends, Claude-written summaries, and saved literature Q&A.
#
# Run from RStudio: open this file and click "Run App".
# Or from the R console: shiny::runApp("path/to/pubtator-trend-summarizer/app")

library(shiny)
library(bslib)
library(DBI)
library(duckdb)
library(dplyr)
library(plotly)

# ---- Data -------------------------------------------------------------------

db <- dbConnect(duckdb::duckdb(), dbdir = "app_data.duckdb", read_only = TRUE)
selected  <- dbReadTable(db, "selected")
counts    <- dbReadTable(db, "topic_year_counts")
field     <- dbReadTable(db, "field_year_counts")
summaries <- dbReadTable(db, "summaries")
qa        <- dbReadTable(db, "rag_log")
titles    <- dbReadTable(db, "article_titles")
dbDisconnect(db, shutdown = TRUE)

counts$year <- as.integer(counts$year)
field$year  <- as.integer(field$year)
titles$pmid <- sprintf("%.0f", as.numeric(titles$pmid))

YEARS     <- 2015:2025
FIELD_PCT <- round(mean(selected$growth_pct - selected$excess_pct), 1)
topics    <- selected$canonical[order(-selected$excess_pct)]

# Topics where manual review found a data-quality problem
caveats <- c(
  "PIK3CD" = paste(
    "Most of these abstracts discuss the broader PI3K/AKT pathway rather than",
    "PIK3CD itself. This rise likely reflects how PubTator tags the term PI3K,",
    "not new research on this specific gene."
  )
)

# ---- Palette (histology stain inspired: hematoxylin and eosin) --------------

HEMA  <- "#3D2E7C"   # hematoxylin: structure, headings, selected state
EOSIN <- "#C8466E"   # eosin: growth, the data being highlighted
INK   <- "#1E1B2E"
MUTED <- "#8C87A3"   # flagged bars
TEXT_MUTED <- "#5F5A78"   # secondary text (passes WCAG AA contrast)
RULE  <- "#E6E3EF"
SLIDE <- "#FBFAFD"

PLOT_FONT <- list(family = "'Public Sans', system-ui, sans-serif", color = INK, size = 13)

# ---- Helpers ----------------------------------------------------------------

model_name <- function(m) if (grepl("haiku-4-5", m)) "Claude Haiku 4.5" else m

# Escape text, turn PMIDs into PubMed links, keep paragraph breaks
linked_paragraphs <- function(txt) {
  paras <- strsplit(txt, "\n\\s*\n")[[1]]
  paras <- vapply(paras, function(p) {
    p <- htmltools::htmlEscape(trimws(p))
    gsub("\\b(\\d{7,9})\\b",
         '<a href="https://pubmed.ncbi.nlm.nih.gov/\\1/" target="_blank" rel="noopener">\\1</a>',
         p, perl = TRUE)
  }, character(1))
  HTML(paste0("<p>", paras, "</p>", collapse = ""))
}

source_list <- function(pmid_string) {
  pmids <- trimws(strsplit(pmid_string, ",")[[1]])
  src <- titles[match(pmids, titles$pmid), ]
  src$pmid <- pmids
  tags$ul(class = "sources", lapply(seq_len(nrow(src)), function(i) {
    title <- if (is.na(src$title[i]) || src$title[i] == "") paste("PMID", src$pmid[i]) else src$title[i]
    tags$li(
      tags$a(href = sprintf("https://pubmed.ncbi.nlm.nih.gov/%s/", src$pmid[i]),
             target = "_blank", rel = "noopener", title),
      tags$span(class = "pmid", paste("PMID", src$pmid[i]))
    )
  }))
}

describe_topic <- function(row) {
  kind <- switch(row$kind, Chemical = "Drug or compound", Gene = "Gene",
                 ProteinMutation = "Mutation", row$kind)
  rel <- if (row$rel_type == "treat") "studied as a treatment for colorectal cancer"
  else "linked to colorectal cancer"
  sprintf("%s %s. %s papers from 2015 to 2025, %s of them since 2023. Grew %.1f%% per year, compared with %.1f%% for colorectal cancer research overall.",
          kind, rel, format(row$total_2015_2025, big.mark = ","),
          format(row$recent_2023_2025, big.mark = ","), row$growth_pct, FIELD_PCT)
}

topic_series <- function(topic) {
  tc <- counts %>% filter(canonical == topic) %>% group_by(year) %>%
    summarise(n = sum(n), .groups = "drop")
  data.frame(year = YEARS) %>%
    left_join(tc, by = "year") %>%
    mutate(n = coalesce(n, 0)) %>%
    left_join(rename(field, field_n = n), by = "year") %>%
    mutate(share = 100 * n / field_n)
}

# ---- Theme and styles -------------------------------------------------------

theme <- bs_theme(
  version = 5,
  bg = SLIDE, fg = INK, primary = HEMA, secondary = MUTED,
  base_font = font_collection("Public Sans", "system-ui", "-apple-system", "Segoe UI", "sans-serif"),
  heading_font = font_collection("Public Sans", "system-ui", "sans-serif"),
  "border-color" = RULE
)

styles <- tags$style(HTML(sprintf("
  :root { --hema: %s; --eosin: %s; --muted: %s; --rule: %s; }
  .intro h1 { color: var(--hema); font-weight: 700; font-size: clamp(1.6rem, 3vw, 2.2rem);
              letter-spacing: -0.01em; max-width: 24ch; margin: 1.5rem 0 .5rem; }
  .intro p  { color: var(--muted); max-width: 68ch; font-size: 1.02rem; }
  .topic-head h2 { color: var(--hema); font-weight: 700; font-size: 1.6rem; margin-bottom: .25rem; }
  .topic-head p  { color: var(--muted); max-width: 60ch; }
  .reading { font-family: 'Source Serif 4', Georgia, serif; font-size: 1.07rem;
             line-height: 1.7; max-width: 68ch; }
  .reading a, .sources a { color: var(--hema); text-underline-offset: 2px; }
  .caveat { border-left: 3px solid var(--eosin); background: #F8EEF2; padding: .7rem 1rem;
            max-width: 68ch; margin: 0 0 1.25rem; }
  .sources { padding-left: 1.1rem; max-width: 72ch; }
  .sources li { margin-bottom: .45rem; }
  .pmid { color: var(--muted); font-size: .85rem; margin-left: .4rem; white-space: nowrap; }
  .fineprint { color: var(--muted); font-size: .85rem; max-width: 68ch; }
  .section-rule { border-top: 1px solid var(--rule); margin: 2rem 0 1.5rem; }
  .qa { border-top: 1px solid var(--rule); padding: 1.75rem 0; }
  .qa h3 { font-size: 1.2rem; font-weight: 600; color: var(--hema); max-width: 60ch; }
  .qa details summary { cursor: pointer; color: var(--hema); font-size: .95rem; }
  .methods { max-width: 72ch; }
  .methods h2 { color: var(--hema); font-size: 1.35rem; font-weight: 700; margin-top: 2rem; }
  .methods table { font-size: .93rem; }
  a:focus-visible, .form-select:focus, .form-check-input:focus {
    outline: 3px solid var(--eosin); outline-offset: 2px; box-shadow: none; }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
", HEMA, EOSIN, TEXT_MUTED, RULE)))

fonts <- tags$link(
  rel = "stylesheet",
  href = "https://fonts.googleapis.com/css2?family=Public+Sans:wght@400;600;700&family=Source+Serif+4:opsz,wght@8..60,400;8..60,600&display=swap"
)

# ---- UI ---------------------------------------------------------------------

topics_tab <- nav_panel(
  "Topics",
  div(class = "intro",
      h1("Which colorectal cancer topics are growing fastest?"),
      p(sprintf(paste(
        "Each bar shows how much faster a topic's yearly publication count grew",
        "from 2015 to 2025 than colorectal cancer research overall (%.1f%% per year).",
        "Click a bar, or choose from the list below, to read what recent papers report."),
        FIELD_PCT))),
  plotlyOutput("ranking", height = "470px"),
  div(class = "section-rule"),
  layout_columns(
    col_widths = c(12, 12, 5, 7),
    selectInput("topic", "Topic", choices = topics, selected = topics[1], width = "100%"),
    uiOutput("topic_head"),
    div(
      radioButtons("view", NULL, inline = TRUE,
                   choices = c("Share of all colorectal cancer papers" = "share",
                               "Number of papers" = "n")),
      plotlyOutput("trend", height = "340px")
    ),
    uiOutput("summary")
  )
)

qa_tab <- nav_panel(
  "Saved questions",
  div(class = "intro",
      h1("Questions answered from the literature"),
      p(sprintf(paste(
        "Each answer was written from the six most relevant of %s recent abstracts,",
        "found by meaning rather than keywords. When the abstracts don't cover a",
        "question, the answer says so instead of guessing. New questions are asked",
        "in the project notebook."),
        format(nrow(titles), big.mark = ",")))),
  uiOutput("qa_list")
)

methods_tab <- nav_panel(
  "Methods",
  div(class = "methods",
      div(class = "intro", h1("How this was built")),
      p("The data come from PubTator3, NCBI's database of genes, drugs, diseases, and",
        "the relationships between them, text-mined from PubMed abstracts."),
      h2("Pipeline"),
      tags$ol(
        tags$li("Filtered PubTator3's bulk relation file to colorectal cancer",
                "(233,074 relationships across 106,817 articles) with DuckDB."),
        tags$li("Retrieved each article's publication year from PubMed's E-utilities API."),
        tags$li(sprintf(paste("Fit a log-linear trend with scikit-learn for every relationship with",
                              "at least 50 papers from 2015 to 2025, and compared its growth with",
                              "colorectal cancer research overall (%.1f%% per year)."), FIELD_PCT)),
        tags$li("Merged duplicate concepts, such as mouse and human versions of the same gene,",
                "and recounted unique articles."),
        tags$li(sprintf("Kept the %d fastest-growing topics with at least 30 papers since 2023.",
                        nrow(selected))),
        tags$li("Summarized each topic from its 8 most recent abstracts with Claude Haiku 4.5,",
                "restricted to those abstracts and required to cite a PMID for every claim."),
        tags$li("Embedded the recent abstracts with sentence-transformers so questions are",
                "answered only from the most relevant retrieved papers.")
      ),
      h2("Evaluation"),
      p("Automated checks confirm that every cited PMID is one of the source abstracts",
        "and that every number in a summary appears in them. Manual review covered what",
        "the checks cannot."),
      tags$table(class = "table",
                 tags$thead(tags$tr(tags$th("Prompt"), tags$th("Checks passed"),
                                    tags$th("Found in review"), tags$th("Change made"))),
                 tags$tbody(
                   tags$tr(tags$td("v1"), tags$td("Test run"),
                           tags$td("A regional subgroup result was presented as the full trial result"),
                           tags$td("Require subgroup and secondary analyses to be labeled")),
                   tags$tr(tags$td("v2"), tags$td("13 of 15"),
                           tags$td("Proportions rewritten as percentages; one topic looked like a tagging artifact"),
                           tags$td("Forbid calculated numbers; flag when abstracts cover a broader topic")),
                   tags$tr(tags$td("v3"), tags$td("15 of 15"),
                           tags$td("The PIK3CD summary flagged its own data limitation"),
                           tags$td("Current version"))
                 )
      ),
      h2("Limitations"),
      tags$ul(
        tags$li("The checks screen for invented numbers and citations, but a number can match",
                "by coincidence, and they do not verify that each claim cites the right paper.",
                "A spot check found one finding attributed to the wrong abstract."),
        tags$li("Trends depend on PubTator's tagging. A change in how a term is tagged can look",
                "like a research trend, as with PIK3CD."),
        tags$li("2026 is excluded because the data cover only part of the year."),
        tags$li("Summaries describe the most recent abstracts, not a systematic review.",
                "Nothing here is medical advice.")
      ),
      h2("Tools"),
      p("Python for the pipeline (DuckDB, pandas, scikit-learn, sentence-transformers,",
        "the Claude API) and R for this dashboard (Shiny, bslib, plotly)."),
      p(tags$a(href = "https://github.com/aaronpong/pubtator-trend-summarizer",
               target = "_blank", rel = "noopener", "Source code on GitHub"))
  )
)

ui <- page_navbar(
  title = "Colorectal cancer research trends",
  theme = theme,
  header = tagList(fonts, styles),
  topics_tab, qa_tab, methods_tab
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {
  
  output$ranking <- renderPlotly({
    d <- selected %>%
      arrange(excess_pct) %>%
      mutate(label  = factor(canonical, levels = canonical),
             colour = case_when(canonical == input$topic ~ HEMA,
                                canonical %in% names(caveats) ~ MUTED,
                                TRUE ~ EOSIN),
             hover  = sprintf("<b>%s</b><br>%.1f%% per year (field: %.1f%%)<br>%s papers since 2023%s",
                              canonical, growth_pct, FIELD_PCT,
                              format(recent_2023_2025, big.mark = ","),
                              ifelse(canonical %in% names(caveats),
                                     "<br>Likely a tagging artifact", "")))
    plot_ly(d, x = ~excess_pct, y = ~label, type = "bar", orientation = "h",
            customdata = ~canonical, source = "rank",
            marker = list(color = d$colour),
            text = ~hover, textposition = "none",
            hovertemplate = "%{text}<extra></extra>") %>%
      layout(xaxis = list(title = "Growth above the field, percentage points per year",
                          gridcolor = RULE, zeroline = FALSE, fixedrange = TRUE),
             yaxis = list(title = "", fixedrange = TRUE),
             font = PLOT_FONT, margin = list(l = 10, r = 10, t = 10, b = 50),
             plot_bgcolor = "rgba(0,0,0,0)", paper_bgcolor = "rgba(0,0,0,0)") %>%
      config(displayModeBar = FALSE) %>%
      event_register("plotly_click")
  })
  
  observeEvent(event_data("plotly_click", source = "rank"), {
    picked <- event_data("plotly_click", source = "rank")$customdata
    if (!is.null(picked)) updateSelectInput(session, "topic", selected = picked)
  })
  
  output$topic_head <- renderUI({
    row <- selected[selected$canonical == input$topic, ][1, ]
    div(class = "topic-head", h2(input$topic), p(describe_topic(row)))
  })
  
  output$trend <- renderPlotly({
    d <- topic_series(input$topic)
    share <- input$view == "share"
    y <- if (share) d$share else d$n
    plot_ly(d, x = ~year, y = y, type = "scatter", mode = "lines+markers",
            line = list(color = EOSIN, width = 2.5),
            marker = list(color = EOSIN, size = 7),
            hovertemplate = if (share) "%{x}: %{y:.2f}% of colorectal cancer papers<extra></extra>"
            else "%{x}: %{y} papers<extra></extra>") %>%
      layout(xaxis = list(title = "", dtick = 2, gridcolor = RULE, fixedrange = TRUE),
             yaxis = list(title = if (share) "Share of colorectal cancer papers (%)" else "Papers per year",
                          rangemode = "tozero", gridcolor = RULE, fixedrange = TRUE),
             font = PLOT_FONT, margin = list(l = 10, r = 10, t = 10, b = 30),
             plot_bgcolor = "rgba(0,0,0,0)", paper_bgcolor = "rgba(0,0,0,0)") %>%
      config(displayModeBar = FALSE)
  })
  
  output$summary <- renderUI({
    s <- summaries[summaries$canonical == input$topic, ]
    if (nrow(s) == 0) {
      return(p(class = "fineprint",
               "No summary for this topic yet. Run the summarization cell in the notebook and re-export the app data."))
    }
    s <- s[1, ]
    n_src <- length(strsplit(s$source_pmids, ",")[[1]])
    tagList(
      if (input$topic %in% names(caveats)) div(class = "caveat", caveats[[input$topic]]),
      div(class = "reading", linked_paragraphs(s$summary)),
      h3("Sources", style = "font-size:1.05rem; font-weight:600; margin-top:1.25rem;"),
      source_list(s$source_pmids),
      p(class = "fineprint", sprintf(
        "Written by %s from the %d most recent abstracts, prompt %s. Automated checks %s.",
        model_name(s$model), n_src, s$prompt_version,
        if (isTRUE(s$passed_checks)) "passed" else "flagged this summary for review"))
    )
  })
  
  output$qa_list <- renderUI({
    if (nrow(qa) == 0) {
      return(p(class = "fineprint",
               "No saved questions yet. Use ask() in the notebook, then re-export the app data."))
    }
    latest <- qa %>%
      group_by(question) %>%
      slice_max(created_at, n = 1, with_ties = FALSE) %>%
      ungroup() %>%
      arrange(created_at)
    tagList(lapply(seq_len(nrow(latest)), function(i) {
      r <- latest[i, ]
      div(class = "qa",
          h3(r$question),
          div(class = "reading", linked_paragraphs(r$answer)),
          p(class = "fineprint", sprintf(
            "Closest match similarity %.2f. Automated checks %s.",
            r$top_score, if (isTRUE(r$passed_checks)) "passed" else "flagged this answer")),
          tags$details(tags$summary("Retrieved abstracts"), source_list(r$retrieved_pmids)))
    }))
  })
}

shinyApp(ui, server)