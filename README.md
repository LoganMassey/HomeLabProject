# Home Lab — Segmented Network & Hybrid Cloud Security Project

A segmented home lab built on a Ubiquiti EdgeRouter, with a Proxmox
virtualization host, enforced inter-segment firewall policy, and a planned
Azure hybrid extension joined over WireGuard.

Built and documented by Logan Massey as a hands-on demonstration of network
segmentation, firewall policy, virtualization, infrastructure as code, and
cloud security fundamentals.

| | |
| --- | --- |
| **Status** | Complete. Segmentation enforcing, hybrid tunnel up, SIEM collecting from two segments. |
| **Last updated** | October 2026 |

---

## Contents

- [Architecture](#architecture)
- [Hardware](#hardware)
- [Addressing](#addressing)
- [Part 1 — EdgeRouter configuration](#part-1--edgerouter-configuration)
- [Part 2 — Firewall policy](#part-2--firewall-policy)
- [Verifying the router](#verifying-the-router)
- [Part 3 — Proxmox virtualization host](#part-3--proxmox-virtualization-host)
- [Part 4 — Wazuh SIEM](#part-4--wazuh-siem)
- [Part 5 — Azure infrastructure as code](#part-5--azure-infrastructure-as-code)
- [Part 6 — WireGuard hybrid tunnel](#part-6--wireguard-hybrid-tunnel)
- [Part 7 — Attack box and detection](#part-7--attack-box-and-detection)
- [Verifying the whole system](#verifying-the-whole-system)
- [Failure log](#failure-log)
- [Known gaps](#known-gaps)
- [Appendix — previous iteration: VLAN segmentation](#appendix--previous-iteration-vlan-segmentation)

Twenty-seven screenshot placeholders are marked 📸 through the document.
`docs/screenshots/README.md` maps each filename to what it should show, flags
the four worth prioritising, and lists what to scrub before publishing.

---

## Architecture

Each device sits on its own routed subnet on a dedicated physical interface.
No trunking, no tagging — the router is the only path between segments, and
every inter-segment flow is explicitly permitted or denied.

```
                    Internet (Spectrum)
                            │
                    ┌───────┴────────┐
                    │  UDM           │  edge router
                    │  192.168.1.0/24│  (not under lab control)
                    └───────┬────────┘
                            │
                            │  eth0 — WAN, DHCP client
                 ┌──────────┴───────────┐
                 │  EdgeRouter ER-4     │
                 │  NAT · DHCP · DNS    │
                 │  firewall policy     │
                 └──┬────────┬───────┬──┘
          eth1 ─────┘        │       └───── eth3
     10.0.20.1/24          eth2          10.0.40.1/24
            │          10.0.30.1/24             │
     ┌──────┴──────┐         │          ┌───────┴──────┐
     │ ThinkCentre │  ┌──────┴────────┐ │   Laptop     │
     │ Kali        │  │   Proxmox     │ │  MANAGEMENT  │
     │ 10.0.20.50  │  │  10.0.30.50   │ │ 10.0.40.101  │
     │ attack box  │  │               │ └──────────────┘
     └─────────────┘  │  ┌──────────┐ │
                      │  │ Wazuh VM │ │  10.0.30.60
                      │  │  SIEM    │ │  manager · indexer · dashboard
                      │  └──────────┘ │
                      │  ┌──────────┐ │
                      │  │ wg-peer  │ │  10.0.30.70
                      │  │ LXC 630  │ │  tunnel endpoint
                      │  └─────┬────┘ │
                      └────────┼──────┘
                               ╎
                               ╎  WireGuard · UDP 51820 · 172.16.0.0/30
                               ╎
     ┌─────────────────────────┴──────────────────────────┐
     │  Azure VNet  10.10.0.0/16        (Central US)      │
     │                                                    │
     │  snet-edge      10.10.1.0/24                       │
     │    └── lab-vm-wireguard  10.10.1.10  [public IP]   │
     │          IP forwarding · NVA                       │
     │                                                    │
     │  snet-workload  10.10.2.0/24                       │
     │    └── lab-vm-workload   10.10.2.4   no public IP  │
     │          UDR: 10.0.0.0/16 → 10.10.1.10             │
     └────────────────────────────────────────────────────┘

     eth4 — spare
```

Three things define the design. Every inter-segment flow crosses the router
and is explicitly permitted or denied. On-prem is `10.0.0.0/16` and Azure is
`10.10.0.0/16`, deliberately non-overlapping. And nothing is NAT'd across the
tunnel, so real source addresses survive end to end — which is what makes the
telemetry worth collecting.

**Policy summary**

| From | To | Allowed |
| ---- | -- | ------- |
| Management (eth3) | Management targets — 22, 443, 8006 | yes |
| Management (eth3) | Azure `10.10.0.0/16` | yes |
| Management (eth3) | Internet | yes |
| Management (eth3) | Other lab segments | **denied, logged** |
| Attack box (eth1) | Wazuh manager — 1514, 1515 only | yes |
| Attack box (eth1) | Internet | yes |
| Attack box (eth1) | Anything else on the lab | **denied, logged** |
| Proxmox (eth2) | Internet | yes |
| Proxmox (eth2) | Any lab segment | **denied, logged** |
| Internet | Anything inbound | **denied** |

The attack box row is the interesting one. It sits on its own segment with
exactly two ports open to one host — enough to report telemetry, not enough
to reach anything else. That constraint is demonstrated under
[Verifying the whole system](#verifying-the-whole-system).


## Hardware

| Device | Spec | Role |
| ------ | ---- | ---- |
| Ubiquiti EdgeRouter ER-4 | 5-port | Routing, DHCP, DNS, firewall |
| Mini PC | i9-13900H, 32 GB RAM | Proxmox VE host |
| Lenovo ThinkCentre | i5-4570T, 8 GB RAM | Kali attack box, Wazuh agent |
| UniFi Dream Machine | — | Upstream edge, separates lab from house |
| Azure | 2 × Standard_B2pts_v2 (ARM64) | Cloud segment, Central US |

---

## Addressing

| Interface | Subnet | Gateway | DHCP pool | Purpose |
| --------- | ------ | ------- | --------- | ------- |
| eth0 | DHCP from UDM | — | — | WAN |
| eth1 | 10.0.20.0/24 | 10.0.20.1 | .100–.199 | ThinkCentre |
| eth2 | 10.0.30.0/24 | 10.0.30.1 | .100–.199 | Proxmox |
| eth3 | 10.0.40.0/24 | 10.0.40.1 | .100–.199 | Management |
| eth4 | — | — | — | Spare |

**Static assignments**

| Address | Host | Notes |
| ------- | ---- | ----- |
| 10.0.20.50 | `kali-thinkcentre` | Attack box, Wazuh agent |
| 10.0.30.50 | `luvmammoth` | Proxmox VE host |
| 10.0.30.60 | `wazuh` | Wazuh manager/indexer/dashboard (Docker) |
| 10.0.30.70 | `wg-peer` | LXC 630, on-prem tunnel endpoint |
| 172.16.0.2 | `wg-peer` `wg0` | Tunnel transit only |
| 172.16.0.1 | `lab-vm-wireguard` `wg0` | Tunnel transit only |
| 10.10.1.10 | `lab-vm-wireguard` | Azure NVA |
| 10.10.2.4 | `lab-vm-workload` | Azure workload, no public IP |

The whole lab summarizes to `10.0.0.0/16`, which is what the Azure side routes
to across the tunnel. Azure is `10.10.0.0/16`. The one-digit difference is
deliberate and the non-overlap is the single most important addressing
decision in the build — overlapping ranges are the usual reason a hybrid
tunnel comes up and then routes nothing.

The `172.16.0.0/30` transit network deserves its own warning, because it caused
four separate failures during the build. It exists only to give the two tunnel
ends an address to talk to each other. It appears in no firewall policy, no
route table, and no NSG rule — and Linux will happily choose it as the source
address for anything a tunnel endpoint originates itself. See the
[failure log](#failure-log).

---

## Part 1 — EdgeRouter configuration

Configured entirely through the EdgeOS CLI rather than the setup wizard.

<img width="1919" height="951" alt="image" src="https://github.com/user-attachments/assets/d1d4d5e9-cce4-4fe2-8bb5-92a644756f59" />

### Starting point

After a factory reset, EdgeOS comes up with `eth0` at `192.168.1.1/24`, every
other interface disabled, no DHCP, no NAT, and `ubnt`/`ubnt` credentials.

Reach it by setting the laptop to a static address on that subnet
(`192.168.1.10/24`, gateway `192.168.1.1`), then browse to
`https://192.168.1.1` and open the CLI.

### Build order

Because `eth0` becomes the WAN, the management interface must exist **before**
`eth0` is repurposed — otherwise the last way in disappears mid-configuration.

```
1. Build eth3 (management) and verify access
2. Move to eth3
3. Convert eth0 to WAN
4. Build eth1 and eth2
5. Firewall policy
```

### Management interface — eth3

```bash
configure
set interfaces ethernet eth3 address 10.0.40.1/24
set interfaces ethernet eth3 description "MGMT-Laptop"

set service dhcp-server shared-network-name MGMT authoritative enable
set service dhcp-server shared-network-name MGMT subnet 10.0.40.0/24 default-router 10.0.40.1
set service dhcp-server shared-network-name MGMT subnet 10.0.40.0/24 dns-server 10.0.40.1
set service dhcp-server shared-network-name MGMT subnet 10.0.40.0/24 start 10.0.40.100 stop 10.0.40.199

set service dns forwarding cache-size 150
set service dns forwarding listen-on eth3
commit
save
```

Move the laptop to eth3, set its adapter to DHCP, and confirm a `10.0.40.x`
lease and access to `https://10.0.40.1` before continuing.

### WAN — eth0

```bash
configure
delete interfaces ethernet eth0 address 192.168.1.1/24
set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 description WAN

set service nat rule 5010 description "masquerade for WAN"
set service nat rule 5010 outbound-interface eth0
set service nat rule 5010 type masquerade
commit
save
```

| Element | Why |
| ------- | --- |
| `address dhcp` | eth0 leases from the upstream UDM |
| Rule number 5010 | EdgeOS convention reserves 5000+ for source NAT, leaving lower numbers for destination NAT (port forwarding) |
| `outbound-interface eth0` | Applies only to WAN-bound traffic; inter-segment traffic is untouched |
| `type masquerade` | Rewrites source address to eth0's and reverses it on replies |

<img width="658" height="376" alt="image" src="https://github.com/user-attachments/assets/dae19abf-217c-4980-9217-19fb687b4665" />


### Lab interfaces — eth1 and eth2

```bash
configure
set interfaces ethernet eth1 address 10.0.20.1/24
set interfaces ethernet eth1 description "ThinkCentre"
set interfaces ethernet eth2 address 10.0.30.1/24
set interfaces ethernet eth2 description "Proxmox"

set service dhcp-server shared-network-name LAB20 authoritative enable
set service dhcp-server shared-network-name LAB20 subnet 10.0.20.0/24 default-router 10.0.20.1
set service dhcp-server shared-network-name LAB20 subnet 10.0.20.0/24 dns-server 10.0.20.1
set service dhcp-server shared-network-name LAB20 subnet 10.0.20.0/24 start 10.0.20.100 stop 10.0.20.199

set service dhcp-server shared-network-name LAB30 authoritative enable
set service dhcp-server shared-network-name LAB30 subnet 10.0.30.0/24 default-router 10.0.30.1
set service dhcp-server shared-network-name LAB30 subnet 10.0.30.0/24 dns-server 10.0.30.1
set service dhcp-server shared-network-name LAB30 subnet 10.0.30.0/24 start 10.0.30.100 stop 10.0.30.199

set service dns forwarding listen-on eth1
set service dns forwarding listen-on eth2
commit
save
```

**DNS is deliberately not listening on eth0.** That is the WAN, and a resolver
answering queries from the internet is an open resolver — usable in
amplification attacks.

<img width="660" height="581" alt="image" src="https://github.com/user-attachments/assets/22d31d4c-8818-47c8-9bec-1f2e7fe3badb" />

### Administrative account

The factory reset restores the default `ubnt` account. Replace it:

```bash
configure
set system login user <username> authentication plaintext-password '<password>'
set system login user <username> level admin
commit
save
```

Log back in as the new user, confirm it works, then remove the default:

```bash
configure
delete system login user ubnt
commit
save
```

---

## Part 2 — Firewall policy

The segmentation only means something once traffic between segments is
denied. Separate subnets alone provide no enforcement — the router will
happily route between them.

<img width="915" height="934" alt="image" src="https://github.com/user-attachments/assets/772aa298-6f31-4c23-8c92-797d55220288" />


### Address and port groups

Named groups keep rules readable and make changes a single edit instead of a
sweep through every rule.

```bash
configure
set firewall group address-group MGMT-TARGETS address 10.0.30.50
set firewall group network-group LAB-NETS network 10.0.20.0/24
set firewall group network-group LAB-NETS network 10.0.30.0/24
set firewall group network-group LAB-NETS network 10.0.40.0/24
set firewall group port-group PVE-MGMT port 8006
set firewall group port-group PVE-MGMT port 22
commit
save
```

### Management segment — eth3

The only segment permitted to reach infrastructure, and only on the ports it
needs.

```bash
configure
set firewall name MGMT_IN default-action drop
set firewall name MGMT_IN description "Admin workstation"

set firewall name MGMT_IN rule 10 action accept
set firewall name MGMT_IN rule 10 state established enable
set firewall name MGMT_IN rule 10 state related enable

set firewall name MGMT_IN rule 20 action accept
set firewall name MGMT_IN rule 20 protocol tcp
set firewall name MGMT_IN rule 20 destination group address-group MGMT-TARGETS
set firewall name MGMT_IN rule 20 destination group port-group PVE-MGMT
set firewall name MGMT_IN rule 20 description "Proxmox UI and SSH"

set firewall name MGMT_IN rule 90 action drop
set firewall name MGMT_IN rule 90 destination group network-group LAB-NETS
set firewall name MGMT_IN rule 90 log enable
set firewall name MGMT_IN rule 90 description "Block other lateral"

set firewall name MGMT_IN rule 100 action accept
set firewall name MGMT_IN rule 100 description "Internet"
commit
save
```

Rule ordering matters: EdgeOS evaluates by rule number and stops at the first
match. Rule 10 lets return traffic back in, rule 20 permits the one path that
is supposed to exist, rule 90 blocks everything else headed into the lab, and
rule 100 catches what is left — which by that point can only be internet-bound.

### Lab segments — eth1 and eth2

Internet access only. No lateral movement in any direction.

```bash
configure
set firewall name LAB20_IN default-action drop
set firewall name LAB20_IN rule 10 action accept
set firewall name LAB20_IN rule 10 state established enable
set firewall name LAB20_IN rule 10 state related enable
set firewall name LAB20_IN rule 90 action drop
set firewall name LAB20_IN rule 90 destination group network-group LAB-NETS
set firewall name LAB20_IN rule 90 log enable
set firewall name LAB20_IN rule 100 action accept

set firewall name LAB30_IN default-action drop
set firewall name LAB30_IN rule 10 action accept
set firewall name LAB30_IN rule 10 state established enable
set firewall name LAB30_IN rule 10 state related enable
set firewall name LAB30_IN rule 90 action drop
set firewall name LAB30_IN rule 90 destination group network-group LAB-NETS
set firewall name LAB30_IN rule 90 log enable
set firewall name LAB30_IN rule 100 action accept
commit
save
```

### WAN protection — eth0

```bash
configure
set firewall name WAN_IN default-action drop
set firewall name WAN_IN description "packets from internet to LAN"
set firewall name WAN_IN rule 10 action accept
set firewall name WAN_IN rule 10 state established enable
set firewall name WAN_IN rule 10 state related enable
set firewall name WAN_IN rule 20 action drop
set firewall name WAN_IN rule 20 state invalid enable

set firewall name WAN_LOCAL default-action drop
set firewall name WAN_LOCAL description "packets from internet to router"
set firewall name WAN_LOCAL rule 10 action accept
set firewall name WAN_LOCAL rule 10 state established enable
set firewall name WAN_LOCAL rule 10 state related enable
set firewall name WAN_LOCAL rule 20 action drop
set firewall name WAN_LOCAL rule 20 state invalid enable
commit
save
```

### Applying the rulesets

Rules do nothing until bound to an interface. Apply the lab segments first,
verify, then management — that ordering keeps a mistake recoverable.

```bash
configure
set interfaces ethernet eth0 firewall in name WAN_IN
set interfaces ethernet eth0 firewall local name WAN_LOCAL
set interfaces ethernet eth1 firewall in name LAB20_IN
set interfaces ethernet eth2 firewall in name LAB30_IN
set interfaces ethernet eth3 firewall in name MGMT_IN
commit
save
```

### `in` vs `local` — the distinction that matters

| Direction | Governs |
| --------- | ------- |
| `in` | Traffic routed **through** the router from that interface |
| `local` | Traffic destined **for the router itself** |
| `out` | Traffic leaving via that interface |

The lab segments currently carry `in` rulesets only, which means the router's
own management interfaces remain reachable from every segment. Known gap —
`local` rulesets restricting router administration to the management segment
are the next change.

---

## Verifying the router

### Segmentation is enforced

From the Proxmox host, attempting to reach the management segment:

```bash
ping 10.0.40.100
# no response — blocked by LAB30_IN rule 90
```

Confirmed at the router as a policy drop rather than a routing failure:

```bash
show firewall name LAB30_IN statistics
```

<img width="617" height="209" alt="image" src="https://github.com/user-attachments/assets/4803a8eb-e52b-42a6-908f-5c1088336412" />

<img width="432" height="224" alt="image" src="https://github.com/user-attachments/assets/50a39ffe-08f2-4e82-9baf-af124a18745b" />

### Permitted paths still work

| Test | From | Expected |
| ---- | ---- | -------- |
| `ping 10.0.30.50` | Management | succeeds |
| `https://10.0.30.50:8006` | Management | loads |
| `ping 8.8.8.8` | Any segment | succeeds |
| `ping google.com` | Any segment | succeeds — proves DNS forwarding |

<img width="548" height="270" alt="image" src="https://github.com/user-attachments/assets/825b874a-22e1-44d1-b30c-afaf77efa3d0" />



### Useful commands

```bash
show interfaces
show configuration commands | match dhcp-server
show configuration commands | match dns
show configuration commands | match nat
show configuration commands | match firewall
show dhcp leases
show firewall name <RULESET> statistics
compare saved          # running config vs what is on disk
show system commit     # commit history
```

Layered connectivity test — each stage isolates a different failure:

| Test | Failure indicates |
| ---- | ----------------- |
| `ping <gateway>` | Link, interface config, or a firewall rule |
| `ping 8.8.8.8` | Routing or NAT |
| `ping google.com` | DNS forwarding only |

### Operational notes

- Run `commit` alone and confirm success before `save`. Chained as
  `commit ; save`, a failed commit still runs `save` and writes the previous
  config back over the new one.
- Paste into the browser CLI in small blocks. Long pastes drop lines silently.
- Reboot to confirm persistence before building the next layer.

---

## Part 3 — Proxmox virtualization host

Proxmox VE 9.x (Debian 13 "trixie") on the mini PC, single NIC, static address
on the `10.0.30.0/24` segment.

<img width="957" height="743" alt="image" src="https://github.com/user-attachments/assets/5b39b541-c5b3-4c78-bc21-929579f3050c" />

### Networking

The one thing worth understanding before touching `/etc/network/interfaces`:
**the bridge holds the IP address, not the physical NIC.** `bridge-ports` names
the physical interface that gets enslaved to the bridge.

```
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.0.30.50/24
    gateway 10.0.30.1
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0
```

Putting the address on `enp1s0` and the interface name on `bridge-ports vmbr0`
is the common inversion, and it produces a host that can reach the network
while every guest is isolated from it.

`pveproxy` reads `/etc/hosts` at startup, so the hostname must resolve to the
real address there or the web UI binds somewhere useless:

```
10.0.30.50  luvmammoth.lab luvmammoth
```

### Repositories

The enterprise repository 403s without a subscription and breaks every
`apt update`. Disable it and add the no-subscription repo:

```bash
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.sources
echo 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription' \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update
```

This reverts on a reinstall, which is worth remembering.

### Guests

| ID | Type | Name | Purpose |
| -- | ---- | ---- | ------- |
| 626 | LXC | `unifi-os-server` | UniFi controller for the switch |
| 630 | LXC | `wg-peer` | WireGuard tunnel endpoint |
| — | VM | `wazuh` | Wazuh manager, indexer, dashboard |

Container IDs cannot have leading zeros. `pct create 0626` fails with
`vmid: invalid format`, which reads like a syntax error and is actually a
range check.

<img width="802" height="484" alt="image" src="https://github.com/user-attachments/assets/9e8e03ee-34e2-4425-8445-221a0a469d83" />



---

## Part 4 — Wazuh SIEM

Wazuh 4.14.8 — manager, indexer and dashboard — on an Ubuntu Server VM at
`10.0.30.60`, deployed from the published Docker Compose single-node stack.

<img width="1913" height="989" alt="image" src="https://github.com/user-attachments/assets/6cebe2de-6ebe-4798-b196-b7896196c0be" />


### Why Docker and not the native installer

The native `wazuh-install.sh` failed four times with
`wazuh-manager could not be started`. The error pointed at systemd and the
real cause was **the disk was full**.

Ubuntu's guided LVM install allocates only part of the volume group to the
root logical volume — a 50 GB disk can yield a ~12 GB root filesystem with the
rest unallocated. Wazuh's vulnerability detector downloads the CTI database on
first start, filled it, and the manager died with a misleading error.

```bash
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

Worth knowing on its own: `df -h` is the first thing to check when a service
fails to start for no visible reason, not the third.

After reclaiming the space the Docker deployment came up first try, so the
switch was partly pragmatism. The compose stack also pins versions and keeps
the three components isolated from the host, which suits a lab that gets
rebuilt.

```bash
sysctl -w vm.max_map_count=262144      # required by the indexer
docker compose up -d
docker compose ps
```

### Agent enrollment

Agents register on TCP 1515 and report on TCP 1514. Both must be published on
the host, not just exposed inside the container network:

```bash
ss -ltnp | grep -E '1514|1515'
```

Install with the manager address set **on the install command itself**:

```bash
WAZUH_MANAGER="10.0.30.60" apt install -y wazuh-agent
```

The variable is consumed by the package's post-install script. If the install
is interrupted and a later unrelated `apt install` completes the pending
configure, the agent ends up with a literal `<address>MANAGER_IP</address>` in
`ossec.conf` and never connects. Always verify:

```bash
grep -A2 '<server>' /var/ossec/etc/ossec.conf
grep -iE "valid key|connected to" /var/ossec/logs/ossec.log
```

<img width="874" height="320" alt="image" src="https://github.com/user-attachments/assets/d31e929f-aa00-43d5-8263-9bf25c39c4c7" />


### Dashboard

```
https://10.0.30.60
```

Typed with `https://` explicitly. A bare IP in the address bar is tried as
`http` first, which times out and looks like the service is down.

<img width="953" height="952" alt="image" src="https://github.com/user-attachments/assets/1f595a5f-3cb6-4b8b-bf98-a1fdf45c0963" />


---

## Part 5 — Azure infrastructure as code

The Azure half is entirely Terraform. Nothing was created in the portal.

```
azure-lab/
├── versions.tf                 provider pinning and features
├── variables.tf                inputs and defaults
├── network.tf                  resource group, VNet, subnets, route table
├── nsg.tf                      network security groups
├── wireguard.tf                tunnel endpoint and workload VMs
├── cloud-init-wireguard.yaml   VM bootstrap
├── monitoring.tf               Log Analytics, storage, VNet flow logs
└── outputs.tf                  connection details
```

<img width="960" height="1032" alt="image" src="https://github.com/user-attachments/assets/fe66ed22-f8d3-4326-9913-7ece8114f9d1" />


### Design decisions worth defending

**Non-overlapping address space.** On-prem `10.0.0.0/16`, Azure `10.10.0.0/16`.

**WireGuard on a VM rather than Azure VPN Gateway.** VPN Gateway speaks
IPsec/IKEv2 only and cannot terminate WireGuard. A small VM also keeps the
routing visible instead of hidden inside a managed service — which matters
when the point of the lab is to understand the routing.

**IP forwarding in two places.** `ip_forwarding_enabled` on the NIC tells the
Azure fabric to deliver transit packets to the VM; `net.ipv4.ip_forward` tells
Linux to forward them. Set one without the other and the tunnel comes up while
nothing crosses it.

**VNet Flow Logs, not NSG Flow Logs.** NSG Flow Logs are on a retirement path.

**No keys in Terraform.** State stores values in plaintext. WireGuard keys are
generated on each host after boot and never enter state or this repository.

**`prevent_deletion_if_contains_resources = false`.** Defender for Cloud
auto-provisions `OperationsManagement/solutions` onto the Log Analytics
workspace. Those are not in Terraform state, so `terraform destroy` leaves the
resource group non-empty and the delete fails. This flag removes a guardrail
against deleting resources someone else created in the same group — acceptable
here because Terraform owns everything in `lab-rg`, and a bad idea in a shared
subscription. It is a deliberate trade-off, not a flag flipped to make an error
go away.

### SKU, region and quota are three different constraints

Getting a VM to deploy took three separate fixes, and conflating them wastes
hours:

| Error | What it actually means |
| ----- | ---------------------- |
| `SkuNotAvailable` with `NotAvailableForSubscription` | The size exists in the region but is not offered to this subscription |
| Restrictions listed per-region in `az vm list-skus` | Capacity or policy restriction for that region |
| `exceeding approved ... Cores quota. Current Limit: 0` | Quota, requested separately and approved per-region |

A new subscription had zero cores of every family, only the ARM64 `Bpsv2`
sizes were offered at all, and the quota request was denied in East US and
approved in Central US. The deployment ended up on `Standard_B2pts_v2` with the
`server-arm64` image SKU in Central US.

```bash
az vm list-skus -l centralus --size Standard_B2pts_v2 -o table
```

<img width="582" height="191" alt="image" src="https://github.com/user-attachments/assets/e214c341-b28f-439a-a66c-f03e247bd32b" />



### Workflow

```bash
terraform validate
terraform plan -out=tfplan
terraform apply "tfplan"
```

`validate` first because a hand-edit that leaves unbalanced braces produces an
`Unclosed configuration block` error that is easy to misread. Saved plans go
stale whenever state changes, which is the cost of being able to read a plan
before applying it — and reading the plan is what caught a `Standard_B1s_v2`
typo before it deployed.

<img width="946" height="111" alt="image" src="https://github.com/user-attachments/assets/1f1c2995-f982-4c48-9fbf-58c23f8bd878" />


> 📸 **Screenshot:** Azure portal — resource group contents and VNet topology view
> `docs/screenshots/16-azure-portal.png`

> 📸 **Screenshot:** Azure portal — edge NSG rules, including the two non-obvious ones
> `docs/screenshots/17-azure-nsg-rules.png`


---

## Part 6 — WireGuard hybrid tunnel

The on-prem end is an unprivileged LXC container on Proxmox rather than the
EdgeRouter itself. EdgeOS has no native WireGuard — only a third-party package
that breaks on firmware updates — and keeping the tunnel off the router means a
mistake there does not take the whole network down.

> 📸 **Screenshot:** `wg show` from both ends with a recent handshake
> `docs/screenshots/18-wireguard-handshake.png`

### Container

```bash
pct create 630 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname wg-peer \
  --cores 1 --memory 512 --swap 512 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=10.0.30.70/24,gw=10.0.30.1 \
  --nameserver 10.0.30.1 \
  --unprivileged 1 --onboot 1 --password
```

An unprivileged container cannot reach `/dev/net/tun` by default. Append to
`/etc/pve/lxc/630.conf` **before** first start:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

`10:200` is the major:minor device number for `/dev/net/tun`; the mount entry
bind-mounts the host's device node into the container. Without both,
`wg-quick up` fails with a confusing "Cannot find device wg0" rather than a
permissions error.

Install `wireguard-tools`, not the `wireguard` metapackage — the metapackage
depends on `wireguard-modules | linux-image-*` and apt satisfies that by
pulling a 108 MB kernel into a container that will never boot one. The module
comes from the Proxmox host.

> 📸 **Screenshot:** `wg-quick up wg0` echoing each command it runs
> `docs/screenshots/19-wgquick-up.png`


### Configuration

**Azure side**, `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address    = 172.16.0.1/30
ListenPort = 51820
PrivateKey = <generated on this host>
PostUp     = for i in 1 2 3 4 5 6 7 8 9 10; do ip route replace 10.0.0.0/16 dev wg0 src 10.10.1.10 && break; sleep 1; done; true

[Peer]
PublicKey  = <on-prem public key>
AllowedIPs = 172.16.0.2/32, 10.0.0.0/16
```

**On-prem side**, in container 630:

```ini
[Interface]
Address    = 172.16.0.2/30
PrivateKey = <generated on this host>
PostUp     = for i in 1 2 3 4 5 6 7 8 9 10; do ip route replace 10.10.0.0/16 dev wg0 src 10.0.30.70 && break; sleep 1; done; true

[Peer]
PublicKey           = <azure public key>
Endpoint            = <azure public IP>:51820
AllowedIPs          = 172.16.0.1/32, 10.10.0.0/16
PersistentKeepalive = 25
```

Write these with a heredoc so the private key goes from file to file without
appearing on screen or in shell history:

```bash
cat > /etc/wireguard/wg0.conf <<EOF
...
PrivateKey = $(cat /etc/wireguard/private.key)
...
EOF
chmod 600 /etc/wireguard/wg0.conf
```

### Four asymmetries worth being able to explain

**Only Azure listens.** The on-prem side sits behind three layers of NAT
(Spectrum → UDM → EdgeRouter) and cannot accept an inbound connection, so it
always dials out. That is also why the NSG opens UDP 51820 in one direction
only.

**`PersistentKeepalive` is on the on-prem side only.** It is the NAT-traversal
side that needs to keep the mapping alive; the listener does not.

**`AllowedIPs` is both a routing table and an ACL.** A packet from a peer is
dropped unless its source falls within that peer's `AllowedIPs`. This is a
genuine conceptual difference from IPsec.

**Neither side masquerades.** The return path for on-prem traffic is handled by
the Azure UDR, so real source IPs survive end to end. NAT would have been
easier and would have made every packet in the flow logs appear to come from
`10.10.1.10`, destroying the attribution the lab exists to demonstrate.

### The `src` hint

Both `PostUp` lines exist because of the same problem in both directions.
Without them, a tunnel endpoint originating its own traffic picks `wg0`'s
address as the source — `172.16.0.1` or `172.16.0.2` — and that address is in
no NSG rule, no UDR, and no firewall group, so the reply is black-holed. The
`src` hint tells the kernel which address to prefer when originating on that
route.

The retry loop matters too. A bare `ip route replace ... src <addr>` fails if
the interface holding that address is not up yet, and `wg-quick` treats a
failed hook as fatal — it tears down the interface it just built. The symptom
is a tunnel that works when you start it by hand and is dead after every
reboot.

### Routing the rest of the lab

The container is the only on-prem host with a route to Azure until the router
is told otherwise:

```
set protocols static route 10.10.0.0/16 next-hop 10.0.30.70
```

And the management segment needs permission to use it:

```
set firewall group network-group AZURE-NETS network 10.10.0.0/16
set firewall name MGMT_IN rule 30 description 'Management to Azure lab over WireGuard'
set firewall name MGMT_IN rule 30 action accept
set firewall name MGMT_IN rule 30 destination group network-group AZURE-NETS
```

Groups must be committed before any rule references them, or the commit fails
with `Group [AZURE-NETS] has not been defined`.

> 📸 **Screenshot:** `show ip route 10.10.0.0/16` and the MGMT_IN ruleset
> `docs/screenshots/20-static-route.png`


### NSG rules the design actually requires

Two rules that are not obvious, both consequences of writing an explicit
deny-all:

```hcl
# Inbound: return traffic from the workload subnet.
# Azure's implicit AllowVnetInBound sits at 65000. An explicit deny-all at
# 4096 fires first and blocks it. The workload VM answers every connection
# and its replies die on the way back into the NVA.
resource "azurerm_network_security_rule" "edge_from_workload" {
  priority                   = 130
  direction                  = "Inbound"
  access                     = "Allow"
  source_address_prefix      = var.subnet_workload_cidr
  destination_address_prefix = "*"   # destination is on-prem, only transiting
  ...
}

# Outbound: transit for on-prem-sourced traffic.
# AllowVnetOutBound at 65000 matches only when BOTH source and destination are
# the VirtualNetwork service tag. That tag covers the VNet plus on-prem ranges
# learned via VPN Gateway or ExpressRoute BGP — not ranges reached over a
# VM-hosted tunnel. A forwarded packet sourced from 10.0.0.0/16 matches no
# outbound allow rule and dies at DenyAllOutBound.
resource "azurerm_network_security_rule" "edge_transit_out" {
  priority                   = 100
  direction                  = "Outbound"
  access                     = "Allow"
  source_address_prefix      = var.onprem_cidr
  destination_address_prefix = var.vnet_cidr
  ...
}
```

Writing an explicit deny means owning every allow it displaces. That is the
single most transferable thing in this repository.

---

## Part 7 — Attack box and detection

Kali Linux on the ThinkCentre at `10.0.20.50`, on its own segment with almost
nothing permitted outbound.

> 📸 **Screenshot:** Kali desktop with the agent connected
> `docs/screenshots/21-kali-agent.png`

### Install notes

Install the desktop only and skip the `top10` and `default` tool
metapackages. At time of writing `kali-tools-top10` depends on `netexec`,
which depends on an unpublished `python3-lsassy` version, and the installer
fails at "Select and install software" with no useful message on screen. The
real error is in `/var/log/syslog` on tty2:

```
E: Unable to satisfy dependencies. Reached two conflicting assignments:
   kali-tools-top10 Depends netexec
   netexec Depends python3-lsassy (>= 3.1.11)
   but none of the choices are installable
```

Rolling distributions break like this periodically. Install the tools that
matter afterwards:

```bash
apt install -y nmap hydra sqlmap wireshark metasploit-framework
```

### Agent

```bash
WAZUH_MANAGER="10.0.30.60" apt install -y wazuh-agent
systemctl enable --now wazuh-agent
```

And the only hole in the segment's policy:

```
set firewall name LAB20_IN rule 20 description 'Wazuh agent to manager'
set firewall name LAB20_IN rule 20 action accept
set firewall name LAB20_IN rule 20 protocol tcp
set firewall name LAB20_IN rule 20 destination address 10.0.30.60
set firewall name LAB20_IN rule 20 destination port 1514,1515
```

Two ports to one host. That is the entire permitted surface from the attack
segment into the rest of the lab.

> 📸 **Screenshot:** `show firewall name LAB20_IN statistics` — rule 20 accepting, rule 90 dropping
> `docs/screenshots/22-lab20-statistics.png`


---

## Verifying the whole system

### Segmentation, demonstrated

From the attack box, against the SIEM host:

```
$ nmap -Pn -p 22,443,1514,1515,8006 10.0.30.60

PORT     STATE    SERVICE
22/tcp   filtered ssh
443/tcp  filtered https
1514/tcp open     fujitsu-dtcns
1515/tcp open     ifor-protocol
8006/tcp filtered wpl-analytics
```

Exactly the two ports policy permits, and nothing else. `-Pn` skips host
discovery, because ICMP is dropped too and nmap would otherwise report the
host as down and scan nothing.

> 📸 **Screenshot:** the nmap output above
> `docs/screenshots/23-nmap-filtered.png`

### Tunnel, both directions

```bash
# from the on-prem container
wg show                              # recent handshake, transfer both ways
nc -w5 -vz 10.10.2.4 22              # reaches the Azure workload VM

# from the Azure workload VM, via az vm run-command
ping -c3 10.0.30.70                  # 38 ms, ttl=63
```

The reverse direction matters. A tunnel that carries traffic one way is a
tunnel with a routing or policy problem you have not found yet.

> 📸 **Screenshot:** Azure workload VM pinging an on-prem container at 38 ms, `ttl=63`
> `docs/screenshots/24-azure-to-onprem.png`


### Reboot survival

```bash
pct reboot 630
# wait, then
wg show
ip route get 10.10.2.4               # expect src 10.0.30.70, not 172.16.0.2
nc -w5 -vz 10.10.2.4 22
```

This test found a real fault — `wg-quick@wg0` failed at boot because its
`PostUp` hook ran before the network was ready. Without the reboot test the
tunnel would have been dead after the next power cut with no obvious reason.

> 📸 **Screenshot:** Post-reboot verification — handshake, correct `src`, successful connect
> `docs/screenshots/25-reboot-survival.png`


### Useful one-liners

```bash
# EdgeRouter — which rules are actually matching
show firewall name LAB20_IN statistics

# Azure — what the fabric thinks the routes are
az network nic show-effective-route-table -g lab-rg -n lab-nic-workload -o table

# Azure — what the NSG would do with a given flow
az network watcher test-ip-flow --vm lab-vm-workload -g lab-rg \
  --direction Inbound --protocol TCP --local 10.10.2.4:22 --remote 10.0.30.70:40000
```

`test-ip-flow` has a blind spot worth knowing: it refuses any local address
that is not the NIC's own, so it cannot evaluate transit traffic through an
NVA at all — which is exactly where NVA problems live.

> 📸 **Screenshot:** `az network nic show-effective-route-table` with the UDR listed as Active
> `docs/screenshots/26-effective-routes.png`


---

## Failure log

Every one of these cost real time. They are recorded because the diagnosis is
the transferable part, not the fix.

| Symptom | Root cause | Lesson |
| ------- | ---------- | ------ |
| Total loss of access after plugging in the WAN | Upstream LAN and lab LAN were both `192.168.1.0/24` | Check for subnet collision before anything else in a double-NAT setup |
| DHCP config silently reverted | `commit ; save` on one line — the commit failed and `save` wrote the old config back | Run `commit` alone, confirm it returns clean, then `save` |
| `Link detected: no`, `Speed: Unknown!` | Hand-crimped cable with split pairs | A cable can link and still lose frames; suspect the physical layer early |
| `Group [PVE_MGMT] has not been defined` | Group referenced in the same commit that defines it, and an underscore where the name used hyphens | Commit groups before the rules that use them; names are exact |
| `vmid: invalid format` | Container ID entered as `0626` | Leading zeros fail a range check, not a syntax check |
| Wazuh manager would not start, ×4 | **Disk full.** Ubuntu's guided LVM left most of the volume group unallocated | `df -h` belongs at the start of any "service won't start" investigation |
| Wazuh dashboard unreachable | Browser tried `http` on a bare IP; and port 443 was missing from the management port group | Type the scheme explicitly |
| `SkuNotAvailable` for `Standard_B1s` | Not capacity — the size was not offered to a new subscription at all | SKU availability, regional restriction and core quota are three separate things |
| Resource group would not delete | Defender for Cloud auto-created solutions on the Log Analytics workspace, outside Terraform state | Managed services create resources your IaC does not know about |
| Tunnel up, nothing crossed it | Tunnel endpoints sourced traffic from `172.16.0.x`, which exists in no policy or route | A transit network that appears nowhere will still be chosen as a source address |
| Azure replies never reached the NVA | Explicit `deny-all-inbound` at priority 4096 pre-empted `AllowVnetInBound` at 65000 | An explicit deny silently removes the implicit allows beneath it |
| New connections from on-prem died at the NVA | `AllowVnetOutBound` requires both ends to match the `VirtualNetwork` tag, which does not cover a VM-hosted tunnel | Established flows survive on NSG state; new ones do not — so the failure looks directional |
| Tunnel dead after every reboot | `wg-quick` `PostUp` ran before the network was up; a failed hook tears the interface down | Make hooks retry and never exit non-zero |
| Kali install failed three times at "Select and install software" | Broken dependency in the Kali rolling repo | Read the whole log before theorizing; two hours went into network theories while the answer sat in `/var/log/syslog` |
| Name resolution failed on one segment | The DNS forwarder had `listen-on` for every interface and no upstream `name-server` at all | A service that listens is not a service that answers |

The pattern across most of these: every individual component reported itself
healthy. Routing was correct, the tunnel showed a handshake, the NSG rules read
correctly, the firewall config matched intent. What broke was the interaction
between layers, and the only tools that found it were `tcpdump` on the transit
hop and rule counters that showed packets arriving and not leaving.

---

## Known gaps

Recorded deliberately rather than quietly left out.

- **The EdgeRouter's own management interfaces are reachable from every
  segment.** Only `in` rulesets exist, not `local`. Traffic *through* the
  router is filtered; traffic *to* the router is not.
- **The router does not answer ICMP on `10.0.20.1`.** Routing through it works.
  Not yet diagnosed; it makes any future problem on that segment harder to see.
- **Wazuh runs from the published Docker Compose deployment with credentials in
  plaintext in `docker-compose.yml`.**
- **The Azure workload VM has no Wazuh agent.** It has no outbound internet —
  Azure retired default outbound access for VMs without a public IP — so the
  package cannot be fetched without sideloading. The agent on the tunnel
  endpoint covers the cloud side for now.
- **The `src` route hints live in `wg0.conf` on each host, not in version
  control.** The Terraform describes the Azure infrastructure; it does not
  describe the tunnel configuration.
- **`prevent_deletion_if_contains_resources = false`** removes a guardrail. See
  Part 5 for why that is acceptable here and would not be elsewhere.
- **Two VMs exceed the Azure free tier.** 750 hours a month covers one. A
  budget alert is set at $5; `az vm deallocate` stops compute billing when the
  workload VM is not in use.

---

## Appendix — previous iteration: VLAN segmentation

The lab originally ran a **router-on-a-stick** topology: a single trunk link
to a managed switch carrying three tagged VLANs, with the router doing all
inter-VLAN routing. When the switch failed, the design moved to the
per-interface routed segments documented above.

Retained here because the two approaches solve the same problem at different
layers, and the tradeoffs are worth recording.

### Topology

```
      EdgeRouter eth0  ── trunk, VLANs 20/30/40 tagged ──┐
                                                         │
                                            ┌────────────┴────────────┐
                                            │   UniFi US-8-60W        │
                                            │   (layer 2 only)        │
                                            └──┬──────┬──────┬────────┘
                                          port 2   port 3   port 4
                                         VLAN 20  VLAN 30  VLAN 40
```

### Router — sub-interfaces

Each VLAN becomes a sub-interface on the physical port. This is the layer 3
half of what a switch SVI does.

```bash
configure
set interfaces ethernet eth0 vif 20 address 10.0.20.1/24
set interfaces ethernet eth0 vif 20 description "ThinkCentre"
set interfaces ethernet eth0 vif 30 address 10.0.30.1/24
set interfaces ethernet eth0 vif 30 description "Proxmox"
set interfaces ethernet eth0 vif 40 address 10.0.40.1/24
set interfaces ethernet eth0 vif 40 description "Laptop"
commit
save
```

### DHCP — one pool per VLAN

```bash
configure
set service dhcp-server shared-network-name VLAN20 authoritative enable
set service dhcp-server shared-network-name VLAN20 subnet 10.0.20.0/24 default-router 10.0.20.1
set service dhcp-server shared-network-name VLAN20 subnet 10.0.20.0/24 dns-server 10.0.20.1
set service dhcp-server shared-network-name VLAN20 subnet 10.0.20.0/24 start 10.0.20.100 stop 10.0.20.199
# repeated for VLAN30 and VLAN40
commit
save
```

### DNS — per sub-interface

`listen-on eth0` does **not** cover the sub-interfaces. Each needs its own
line, or clients receive addresses but no name resolution.

```bash
configure
set service dns forwarding listen-on eth0.20
set service dns forwarding listen-on eth0.30
set service dns forwarding listen-on eth0.40
commit
save
```

### Switch side

The US-8-60W is a layer 2 switch with no SVI capability — it cannot route
between VLANs at all, which is why every gateway address lives on the router.

It also has no usable CLI of its own. UniFi switches are configured through a
controller: VLANs are defined once as networks, then each port is assigned a
Native VLAN. Changes made over the switch's SSH interface are overwritten on
the next provision.

| Port | Native VLAN | Tagged |
| ---- | ----------- | ------ |
| 1 | Default (untagged management) | 20, 30, 40 — trunk to router |
| 2 | VLAN 20 | — |
| 3 | VLAN 30 | — |
| 4 | VLAN 40 | — |

Networks were created as **third-party gateway** (VLAN-only) so the
controller would not run a competing DHCP server on subnets the EdgeRouter
already served. DHCP Guarding was enabled with the EdgeRouter as the trusted
server, so offers from anywhere else are dropped.

A self-hosted UniFi controller ran in an LXC on the Proxmox host, on the
untagged management network alongside the switch it managed.

### Why the change

The switch developed a hardware fault and was removed. With four devices and
a five-port router, dedicating a physical interface per segment produces the
same isolation with less moving machinery.

### What each approach costs

| | Router-on-a-stick | Per-interface routed |
| --- | --- | --- |
| Segments | Limited by VLAN space, not ports | One per physical port |
| Hardware | Needs a managed switch | Router only |
| Inter-segment traffic | Crosses the trunk twice — in and back out | Direct between interfaces |
| Failure domain | Switch failure takes down every segment | One port, one segment |
| Config surface | Two devices, two models to keep in sync | One device |

The trunk hairpin is the constraint that justifies a layer 3 switch at larger
scale: all inter-VLAN traffic contends for a single link's bandwidth. At four
devices it is irrelevant; in a building it is not.

> 📸 **Screenshot:** UniFi controller — port assignments and VLAN networks
> `docs/screenshots/27-vlan-ports.png`

---

*Proxmox, Wazuh, and the Azure hybrid extension are in progress and will be
documented as each is completed.*
