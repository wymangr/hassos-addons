# Changelog

## [0.0.6] - 2025-14-25

- Bump Grafana Alloy version from `1.7.5` to [1.8.3](https://github.com/grafana/alloy/releases/tag/v1.8.3)
- Bump base image from `7.8.0` to `7.8.3`
- Opened ports `5514` (UDP) and `5601` (TPC) for loki.source.syslog
- Added option to enable basic Loki Syslog source

## [0.0.5] - 2025-03-25

- Fix apparmor config for config directory [#3](https://github.com/wymangr/hassos-addons/issues/3)

## [0.0.4] - 2025-03-25

- Bump Grafana Alloy version from `1.7.2` to [1.7.5](https://github.com/grafana/alloy/releases/tag/v1.7.5)
- Bump base image from `7.7.1` to `7.8.0`
- Fix missing config mount for override_config [#3](https://github.com/wymangr/hassos-addons/issues/3)

## [0.0.3] - 2025-03-11

- Remove "System protection" requirement. See [README.md](https://github.com/wymangr/hassos-addons/blob/main/grafana_alloy/README.md#protection-mode) for more details
- Remove unused permissions in config.yaml
- Add [prometheus.exporter.self](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.self/) to collect metrics about Alloy
- Bump Grafana Alloy version to [1.7.2](https://github.com/grafana/alloy/releases/tag/v1.7.2)
- Remove unused dependencies in Dockerfile
- Add Apparmor Profile

## [0.0.2] - 2025-03-09

- Added `enable_prometheus` option
- Added `enable_unix_component` option
- Added `enable_process_component` option
- Added `prometheus_scrape_interval` option
- Added `enable_loki` option
- Added "servername" label to loki config
- Added translations
- Added development environment

## [0.0.1] - 2025-03-08

- Initial release
