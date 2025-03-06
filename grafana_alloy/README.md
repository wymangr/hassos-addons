# Grafana Alloy

[Grafana Alloy](https://grafana.com/docs/alloy) combines the strengths of the leading collectors into one place. Whether observing applications, infrastructure, or both, Grafana Alloy can collect, process, and export telemetry signals to scale and future-proof your observability approach.

Currently, this add-on supports the following components:

- [prometheus.scrape](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.scrape/) - Sends metrics to Prometheus write endpoint.
- [prometheus.exporter.unix](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.unix/) - Uses the [node_exporter](https://github.com/prometheus/node_exporter) to expose Home Assistant Hardware and OS metrics for *nix-based systems.
- [prometheus.exporter.process](https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.exporter.process/) - Enables [process_exporter](https://github.com/ncabatoff/process-exporter) to collect Home Assistant process stats from /proc.
- [loki.write](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/) - Sends logs to Loki instance.
- [loki.source.journal](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/) - Collects Home Assistant Journal logs to send to Loki.

**Note**: Because this add-on requires access to host level data (CPU, Memory, Disk, etc), Disabling Protection mode is required. Please inspect the code of this add-on before you run it.

## Installation

1. Add [repository](https://github.com/wymangr/hassos-addons) to Home Assistant.
1. Search for "Grafana Alloy" in the Home Assistant add-on store and install it.
1. Disable "Protection mode" in the add-on panel.
1. Update configuration on the add-on "Configuration" Tab:
    - Add Prometheus Write Endpoint (Ex: http://<host>:<port>/api/v1/write) **Note**: Prometheus needs to be configured to enable the remote write receiver.
    - Optional - Add Loki Endpoint if you want to collect logs. (Ex: http://<host>:<port>/api/v1/push)
1. Start the add-on.
1. Check the `Logs` to confirm the add-on started successfully.
1. You can also visit the Grafana Alloy Web UI by visiting `http://<homeassistnat_ip>:12345` in your browser.

## Configuration

Config     | Description | Default value | Required
-|-|-|-
`prometheus_write_endpoint` | Prometheus Endpoint to write metrics to. |  | Yes
`loki_endpoint` | Loki Endpoint to write logs to. Will not collect logs if left blank. |  | No
`servername_tag` | Optional "servername" tag to add to Prometheus metrics. | HomeAssistant | No
`instance_tag` | Optional value to overwrite the "instance" tag for Prometheus metrics. | HomeAssistant | No
`overrid_config` | Enable if you want to override the provided Alloy config with your own. | false | No
`overide_config_path` | Path to optional Alloy config file. | /config/alloy/example.alloy | If overrid_config=true

Home Assistant Journal Logs will only be collected if `loki_endpoint` is supplied. 

If `override_config` is true and a valid Alloy config file is supplied in `overide_config_path`, all other options will be ignored. 


## Support

- Tested on `aarch64`, however it should also work on `amd64`

## Todo

- [ ] Add more customization options (Enable/disable components, scrape_interval, etc..)
- [ ] Add Github workflows
- [ ] Build and publish a docker image so users don't have to build the image on every install
- [ ] Verify all permissions added to `config.yaml` are required and remove unneeded ones