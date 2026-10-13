# Screenshots

Images referenced from the main README. Each placeholder there names the
filename to use, in the order they appear in the document.

| File | Shows |
| ---- | ----- |
| `01-topology.png` | network topology / rack photo |
| `02-edgeos-dashboard.png` | EdgeOS dashboard showing all interfaces |
| `03-wan-lease.png` | `show interfaces ethernet eth0` with an active WAN lease |
| `04-dhcp-pools.png` | `show configuration commands \| match dhcp-server` |
| `05-firewall-rulesets.png` | EdgeOS firewall ruleset overview |
| `06-lateral-blocked.png` | blocked ping alongside the incrementing drop counter |
| `07-mgmt-access.png` | management access to Proxmox working |
| `08-proxmox-summary.png` | Proxmox summary page showing the node and guests |
| `09-proxmox-guests.png` | `pct list` showing the running containers and the Wazuh VM |
| `10-wazuh-dashboard.png` | Wazuh dashboard overview with agents reporting |
| `11-agent-connected.png` | `ossec.log` showing `Valid key received` and `Connected to the server` |
| `12-wazuh-agents.png` | Wazuh **Agents** page — both agents listed as Active |
| `13-terraform-apply.png` | `terraform apply` completing, and the resource group in the portal |
| `14-azure-quota.png` | `az vm list-skus` output and the approved quota request |
| `15-terraform-plan.png` | `terraform plan` output before applying — the step that catches typos |
| `16-azure-portal.png` | Azure portal — resource group contents and VNet topology view |
| `17-azure-nsg-rules.png` | Azure portal — edge NSG rules, including the two non-obvious ones |
| `18-wireguard-handshake.png` | `wg show` from both ends with a recent handshake |
| `19-wgquick-up.png` | `wg-quick up wg0` echoing each command it runs |
| `20-static-route.png` | `show ip route 10.10.0.0/16` and the MGMT_IN ruleset |
| `21-kali-agent.png` | Kali desktop with the agent connected |
| `22-lab20-statistics.png` | `show firewall name LAB20_IN statistics` — rule 20 accepting, rule 90 dropping |
| `23-nmap-filtered.png` | the nmap output above |
| `24-azure-to-onprem.png` | Azure workload VM pinging an on-prem container at 38 ms, `ttl=63` |
| `25-reboot-survival.png` | Post-reboot verification — handshake, correct `src`, successful connect |
| `26-effective-routes.png` | `az network nic show-effective-route-table` with the UDR listed as Active |
| `27-vlan-ports.png` | UniFi controller — port assignments and VLAN networks |

## The four that matter most

If you only capture a handful, capture these — they show the lab *doing*
something rather than showing that it exists.

| File | Why |
| ---- | --- |
| `23-nmap-filtered.png` | Segmentation proven from an attacker's position: exactly two ports reachable, everything else filtered |
| `18-wireguard-handshake.png` | The hybrid tunnel live, both ends, with traffic counters moving |
| `24-azure-to-onprem.png` | A cloud VM reaching a container in your house — the whole project in one line of output |
| `12-wazuh-agents.png` | Two agents on two segments, one of them across the tunnel, reporting to one SIEM |

## Before committing a screenshot

- Crop out browser tabs that reveal unrelated sites
- Blur or crop any public IP or MAC you would rather not publish — the
  repository may not stay private
- The Azure public IP appears in `wg show` output, Terraform outputs and the
  portal; the home public IP appears in NSG source rules
- Verbose tool output sometimes echoes passwords; check before capturing
- Terminal screenshots are more readable at a larger font size — bump it
  before you capture, not after

## Embedding

The README uses placeholder callouts. Replace each with a standard image
reference:

```markdown
![nmap from the attack box showing only the two permitted ports](docs/screenshots/23-nmap-filtered.png)
```

Alt text is worth writing properly — it is what someone reads when the image
fails to load, and it is the only part a recruiter skimming on a phone may
actually process.

## Capturing on Windows

`Win + Shift + S` for a region, then paste into Paint and save as PNG. For
terminal output specifically, select the text and paste it into the README as a
fenced code block instead — it is searchable, copyable, diffable and legible on
a phone, which a screenshot of a terminal is not. Save the screenshots for
anything with a graphical interface: the Wazuh dashboard, the Azure portal, the
Proxmox UI, the UniFi controller.
