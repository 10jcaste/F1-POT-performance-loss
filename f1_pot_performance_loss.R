# ============================================================
# f1-POT-performance-loss
# Peaks Over Threshold analysis of Formula 1 lap-time data
# Season: 2024
#
# Data source:
# OpenF1 API: https://openf1.org/
#
# This script downloads Formula 1 lap-time data, constructs a
# stint-normalized relative performance-loss variable, fits a
# Generalized Pareto Distribution to high-threshold exceedances,
# and estimates the upper endpoint of the extreme-loss tail.
# ============================================================


# ------------------------------------------------------------
# 1. Packages
# ------------------------------------------------------------

# Required packages:
# install.packages(c(
#   "httr2", "jsonlite", "dplyr", "readr",
#   "stringr", "purrr", "ismev", "ggplot2", "evd"
# ))

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(dplyr)
  library(readr)
  library(stringr)
  library(purrr)
  library(ismev)
  library(ggplot2)
  library(evd)
})


# ------------------------------------------------------------
# 2. Output directories
# ------------------------------------------------------------

dir.create("data", showWarnings = FALSE)
dir.create("results", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)


# ------------------------------------------------------------
# 3. OpenF1 API helper
# ------------------------------------------------------------

get_openf1 <- function(endpoint, query = list()) {
  
  url <- paste0("https://api.openf1.org/v1/", endpoint)
  
  req <- request(url)
  
  if (length(query) > 0) {
    req <- req_url_query(req, !!!query)
  }
  
  resp <- req |>
    req_retry(max_tries = 3) |>
    req_perform()
  
  txt <- resp_body_string(resp)
  
  if (nchar(txt) == 0 || txt == "[]") {
    return(tibble())
  }
  
  data <- fromJSON(txt, flatten = TRUE) |>
    as_tibble()
  
  return(data)
}


# ------------------------------------------------------------
# 4. 2024 race sessions
# ------------------------------------------------------------

sessions_2024 <- get_openf1(
  endpoint = "sessions",
  query = list(year = 2024)
)

races_2024 <- sessions_2024 |>
  filter(session_name == "Race", is_cancelled == FALSE) |>
  select(
    session_key,
    country_name,
    location,
    circuit_short_name,
    date_start,
    year
  ) |>
  arrange(date_start)

cat("Number of 2024 race sessions:", nrow(races_2024), "\n")


# ------------------------------------------------------------
# 5. Race-level processing function
# ------------------------------------------------------------

process_race <- function(session_key_i) {
  
  message("Processing session_key = ", session_key_i)
  
  laps <- get_openf1(
    endpoint = "laps",
    query = list(session_key = session_key_i)
  )
  
  stints <- get_openf1(
    endpoint = "stints",
    query = list(session_key = session_key_i)
  )
  
  drivers <- get_openf1(
    endpoint = "drivers",
    query = list(session_key = session_key_i)
  )
  
  if (nrow(laps) == 0 || nrow(stints) == 0 || nrow(drivers) == 0) {
    warning("Missing data for session_key = ", session_key_i)
    return(tibble())
  }
  
  relative_lap_data <- laps |>
    filter(!is.na(lap_duration)) |>
    left_join(
      stints,
      by = join_by(
        session_key,
        driver_number,
        between(lap_number, lap_start, lap_end)
      )
    ) |>
    left_join(
      drivers |>
        select(session_key, driver_number, full_name, team_name),
      by = c("session_key", "driver_number")
    ) |>
    
    # Keep laps with identified stint, compound and tyre age.
    filter(!is.na(stint_number)) |>
    filter(!is.na(compound)) |>
    filter(!is.na(tyre_age_at_start)) |>
    
    # Approximate tyre age for each lap.
    mutate(
      tyre_age_laps = tyre_age_at_start + (lap_number - lap_start)
    ) |>
    
    # Stint-level normalization.
    group_by(
      session_key,
      driver_number,
      full_name,
      team_name,
      stint_number,
      compound
    ) |>
    
    # Remove very short stints.
    filter(n() >= 5) |>
    
    # Relative performance loss with respect to the best lap in the stint.
    mutate(
      best_lap_stint = min(lap_duration, na.rm = TRUE),
      performance_loss_percent =
        100 * (lap_duration - best_lap_stint) / best_lap_stint
    ) |>
    ungroup() |>
    
    # Add race information.
    left_join(
      races_2024,
      by = "session_key"
    )
  
  return(relative_lap_data)
}


# ------------------------------------------------------------
# 6. Full-season processing
# ------------------------------------------------------------

process_sessions_in_batches <- function(session_keys, batch_size = 10, pause_seconds = 120) {
  
  session_batches <- split(
    session_keys,
    ceiling(seq_along(session_keys) / batch_size)
  )
  
  output <- vector("list", length(session_batches))
  
  for (i in seq_along(session_batches)) {
    
    message("Processing batch ", i, " of ", length(session_batches))
    
    output[[i]] <- map_dfr(session_batches[[i]], process_race)
    
    if (i < length(session_batches)) {
      message("Pausing for ", pause_seconds, " seconds to reduce API rate-limit risk...")
      Sys.sleep(pause_seconds)
    }
  }
  
  bind_rows(output)
}

relative_lap_data_2024 <- process_sessions_in_batches(
  session_keys = races_2024$session_key,
  batch_size = 10,
  pause_seconds = 120
)


# ------------------------------------------------------------
# 7. Data cleaning
# ------------------------------------------------------------

clean_lap_data_2024 <- relative_lap_data_2024 |>
  
  # Remove pit-out laps.
  filter(is.na(is_pit_out_lap) | is_pit_out_lap == FALSE) |>
  
  # Remove non-representative race-pace laps.
  filter(performance_loss_percent <= 10)

write_csv(
  clean_lap_data_2024,
  "data/clean_lap_data_2024.csv"
)


# ------------------------------------------------------------
# 8. POT sample
# ------------------------------------------------------------

# Variable of interest:
# stint-normalized relative performance loss, measured in percentage points.
X <- clean_lap_data_2024$performance_loss_percent
X <- X[!is.na(X)]

n <- length(X)

summary_X <- summary(X)

cat("\nClean sample size:", n, "\n")


# ------------------------------------------------------------
# 9. POT-GPD fitting function
# ------------------------------------------------------------

fit_pot_threshold <- function(X, threshold_probability) {
  
  threshold <- quantile(X, probs = threshold_probability, na.rm = TRUE)
  threshold <- as.numeric(threshold)
  
  number_exceedances <- sum(X > threshold)
  exceedance_proportion <- number_exceedances / length(X)
  
  excesses <- X[X > threshold] - threshold
  
  pot_fit <- gpd.fit(
    X,
    threshold = threshold,
    show = FALSE
  )
  
  sigma_hat <- pot_fit$mle[1]
  xi_hat <- pot_fit$mle[2]
  
  se_sigma <- pot_fit$se[1]
  se_xi <- pot_fit$se[2]
  
  if (xi_hat < 0) {
    excess_upper_endpoint <- -sigma_hat / xi_hat
    upper_endpoint <- threshold + excess_upper_endpoint
  } else {
    excess_upper_endpoint <- NA_real_
    upper_endpoint <- NA_real_
  }
  
  list(
    threshold_probability = threshold_probability,
    threshold = threshold,
    number_exceedances = number_exceedances,
    exceedance_proportion = exceedance_proportion,
    excesses = excesses,
    pot_fit = pot_fit,
    sigma_hat = sigma_hat,
    xi_hat = xi_hat,
    se_sigma = se_sigma,
    se_xi = se_xi,
    excess_upper_endpoint = excess_upper_endpoint,
    upper_endpoint = upper_endpoint
  )
}


# ------------------------------------------------------------
# 10. Main POT-GPD fit: 95th percentile threshold
# ------------------------------------------------------------

main_pot <- fit_pot_threshold(
  X = X,
  threshold_probability = 0.95
)

u <- main_pot$threshold
Nu <- main_pot$number_exceedances
prop_Nu <- main_pot$exceedance_proportion
Y <- main_pot$excesses
m <- length(Y)

sigma_hat <- main_pot$sigma_hat
xi_hat <- main_pot$xi_hat
se_sigma <- main_pot$se_sigma
se_xi <- main_pot$se_xi
excess_upper_endpoint <- main_pot$excess_upper_endpoint
upper_endpoint <- main_pot$upper_endpoint

summary_Y <- summary(Y)


# ------------------------------------------------------------
# 11. Results table
# ------------------------------------------------------------

pot_results <- tibble(
  n = n,
  threshold_probability = 0.95,
  threshold_u = u,
  number_exceedances = Nu,
  exceedance_proportion = prop_Nu,
  sigma_hat = sigma_hat,
  xi_hat = xi_hat,
  se_sigma = se_sigma,
  se_xi = se_xi,
  excess_upper_endpoint = excess_upper_endpoint,
  upper_endpoint = upper_endpoint
)

cat("\n================ POT-GPD ANALYSIS RESULTS ================\n\n")

cat("Clean sample size, n:", n, "\n")
cat("Threshold probability:", 0.95, "\n")
cat("Threshold, u:", u, "\n")
cat("Number of exceedances, Nu:", Nu, "\n")
cat("Exceedance proportion, Nu/n:", prop_Nu, "\n\n")

cat("Estimated scale parameter, sigma_hat:", sigma_hat, "\n")
cat("Estimated shape parameter, xi_hat:", xi_hat, "\n")
cat("Standard error of sigma_hat:", se_sigma, "\n")
cat("Standard error of xi_hat:", se_xi, "\n\n")

cat("Estimated upper endpoint for excesses:", excess_upper_endpoint, "\n")
cat("Estimated upper endpoint for X:", upper_endpoint, "\n\n")

cat("Summary of X:\n")
print(summary_X)

cat("\nSummary of threshold excesses Y:\n")
print(summary_Y)

cat("\nResults table:\n")
print(pot_results)

write_csv(
  pot_results,
  "results/pot_results_f1_2024.csv"
)


# ------------------------------------------------------------
# 12. Plots
# ------------------------------------------------------------

# 12.1 Distribution of X and POT threshold.

distribution_threshold_plot <- ggplot(data.frame(X = X), aes(x = X)) +
  geom_histogram(
    bins = 50,
    fill = "grey80",
    colour = "grey30"
  ) +
  geom_vline(
    xintercept = u,
    linetype = "dashed",
    linewidth = 1
  ) +
  labs(
    title = "Distribution of relative performance loss",
    subtitle = paste0("POT threshold: u = ", round(u, 4), "%"),
    x = "Relative loss with respect to the best lap in the stint (%)",
    y = "Frequency"
  ) +
  theme_minimal()

print(distribution_threshold_plot)


# 12.2 Threshold exceedances and fitted GPD density.

y_grid <- seq(0, max(Y), length.out = 500)

density_data <- data.frame(
  y = y_grid,
  density = dgpd(
    y_grid,
    loc = 0,
    scale = sigma_hat,
    shape = xi_hat
  )
)

gpd_exceedances_plot <- ggplot(data.frame(Y = Y), aes(x = Y)) +
  geom_histogram(
    aes(y = after_stat(density)),
    bins = 35,
    fill = "grey80",
    colour = "grey30"
  ) +
  geom_line(
    data = density_data,
    aes(x = y, y = density),
    linewidth = 1
  ) +
  labs(
    title = "Threshold exceedances and fitted GPD",
    subtitle = paste0(
      "Estimates: sigma = ", round(sigma_hat, 4),
      ", xi = ", round(xi_hat, 4)
    ),
    x = "Excess over threshold (%)",
    y = "Density"
  ) +
  theme_minimal()

print(gpd_exceedances_plot)


# 12.3 QQ-plot of threshold excesses.

ordered_excesses <- sort(Y)
empirical_probabilities <- ppoints(length(ordered_excesses))

qq_data <- data.frame(
  theoretical = qgpd(
    empirical_probabilities,
    loc = 0,
    scale = sigma_hat,
    shape = xi_hat
  ),
  empirical = ordered_excesses
)

gpd_qq_plot <- ggplot(qq_data, aes(x = theoretical, y = empirical)) +
  geom_point(size = 1.3, alpha = 0.7) +
  geom_abline(
    intercept = 0,
    slope = 1,
    linetype = "dashed",
    linewidth = 1
  ) +
  labs(
    title = "QQ-plot of threshold exceedances",
    subtitle = "Empirical quantiles versus fitted GPD quantiles",
    x = "Theoretical GPD quantiles (%)",
    y = "Empirical excess quantiles (%)"
  ) +
  theme_minimal()

print(gpd_qq_plot)


# 12.4 Return levels.

lambda_u <- Nu / n
return_periods <- seq(2, 1000, length.out = 500)

return_levels <- u +
  (sigma_hat / xi_hat) * ((return_periods * lambda_u)^xi_hat - 1)

return_level_data <- data.frame(
  return_period = return_periods,
  return_level = return_levels
)

return_levels_plot <- ggplot(return_level_data, aes(x = return_period, y = return_level)) +
  geom_line(linewidth = 1) +
  geom_hline(
    yintercept = upper_endpoint,
    linetype = "dashed",
    linewidth = 1
  ) +
  scale_x_log10() +
  labs(
    title = "Return levels estimated with the POT-GPD model",
    subtitle = paste0(
      "Estimated upper endpoint: ",
      round(upper_endpoint, 4), "%"
    ),
    x = "Approximate return period, measured in laps",
    y = "Relative performance loss (%)"
  ) +
  theme_minimal()

print(return_levels_plot)


# ------------------------------------------------------------
# 13. Save plots
# ------------------------------------------------------------

ggsave(
  "figures/figure_1_distribution_threshold.jpg",
  distribution_threshold_plot,
  width = 8,
  height = 5,
  dpi = 300
)

ggsave(
  "figures/figure_2_gpd_exceedances.jpg",
  gpd_exceedances_plot,
  width = 8,
  height = 5,
  dpi = 300
)

ggsave(
  "figures/figure_3_gpd_qqplot.jpg",
  gpd_qq_plot,
  width = 8,
  height = 5,
  dpi = 300
)

ggsave(
  "figures/figure_4_return_levels.jpg",
  return_levels_plot,
  width = 8,
  height = 5,
  dpi = 300
)


# ------------------------------------------------------------
# 14. Threshold comparison: 90th and 95th percentiles
# ------------------------------------------------------------

threshold_comparison <- bind_rows(
  fit_pot_threshold(X, 0.90) |>
    (\(z) tibble(
      threshold_probability = z$threshold_probability,
      threshold_u = z$threshold,
      number_exceedances = z$number_exceedances,
      exceedance_proportion = z$exceedance_proportion,
      sigma_hat = z$sigma_hat,
      xi_hat = z$xi_hat,
      se_sigma = z$se_sigma,
      se_xi = z$se_xi,
      upper_endpoint = z$upper_endpoint
    ))(),
  
  fit_pot_threshold(X, 0.95) |>
    (\(z) tibble(
      threshold_probability = z$threshold_probability,
      threshold_u = z$threshold,
      number_exceedances = z$number_exceedances,
      exceedance_proportion = z$exceedance_proportion,
      sigma_hat = z$sigma_hat,
      xi_hat = z$xi_hat,
      se_sigma = z$se_sigma,
      se_xi = z$se_xi,
      upper_endpoint = z$upper_endpoint
    ))()
)

cat("\n================ THRESHOLD COMPARISON ================\n\n")
print(threshold_comparison)

write_csv(
  threshold_comparison,
  "results/threshold_comparison_pot_f1_2024.csv"
)


# ------------------------------------------------------------
# 15. End of script
# ------------------------------------------------------------

cat("\nAnalysis completed successfully.\n")
cat("Files written to: data/, results/ and figures/.\n")
