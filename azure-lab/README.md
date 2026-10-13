# Hybrid Cloud Security Lab — Azure Infrastructure

Terraform for the Azure half of a hybrid lab. An on-prem segmented network
(EdgeRouter, UniFi switch, Proxmox) is joined to an Azure VNet over a
WireGuard tunnel, with flow telemetry from both sides landing in Log
Analytics.

**Status:** phase 1 — network foundation.

---

## What this builds

```
          Internet
              │
              │  UDP 51820, restricted to one source IP
┌─────────────┴──────────────────────────────┐
│  Azure VNet  10.10.0.0/16                  │
│                                            │
│  snet-edge      10.10.1.0/24               │
│    └── vm-wireguard  10.10.1.10  [pub IP]  │
│          IP forwarding on (NIC + sysctl)   │
│                                            │
│  snet-workload  10.10.2.0/24               │
│    └── vm-workload   no public IP          │
│          UDR: 10.0.0.0/16 → 10.10.1.10     │
└────────────────────────────────────────────┘
              ╎
              ╎  WireGuard tunnel
              ╎
┌─────────────┴──────────────────────────────┐
│  On-prem  10.0.0.0/16                      │
│    10.0.1.0/24   management                │
│    10.0.20.0/24  VLAN 20                   │
│    10.0.30.0/24  VLAN 30 — Proxmox         │
│    10.0.40.0/24  VLAN 40                   │
└────────────────────────────────────────────┘
```

| File | Contains |
| ---- | -------- |
| `versions.tf` | Provider pinning |
| `variables.tf` | Inputs and defaults |
| `network.tf` | Resource group, VNet, subnets, UDR |
| `nsg.tf` | Network security groups |
| `wireguard.tf` | Tunnel endpoint and workload VMs |
| `cloud-init-wireguard.yaml` | VM bootstrap |
| `monitoring.tf` | Log Analytics, storage, VNet flow logs |
| `outputs.tf` | Connection details |

---

## Design decisions worth defending

**Non-overlapping address space.** On-prem is `10.0.0.0/16`; Azure is
`10.10.0.0/16`. Overlapping ranges are the single most common reason a
hybrid tunnel comes up and then routes nothing — the same mistake, at a
different scale, as the `192.168.1.0/24` collision that broke the on-prem
build.

**WireGuard on a VM rather than Azure VPN Gateway.** VPN Gateway speaks
IPsec/IKEv2 only and cannot terminate WireGuard. A B1s VM is free-tier
eligible where a gateway may not be, and the routing stays visible instead
of being hidden inside a managed service.

**IP forwarding in two places.** `ip_forwarding_enabled` on the NIC tells
the Azure fabric to deliver transit packets to the VM; `net.ipv4.ip_forward`
tells Linux to forward them. Set one without the other and the tunnel comes
up while nothing crosses it.

**VNet Flow Logs, not NSG Flow Logs.** NSG Flow Logs are on a retirement
path. Anything built now should target the VNet.

**Explicit deny rules.** Azure's hidden default rules already deny inbound
at priority 65500. The explicit denies at 4096 are redundant but make the
deny-by-default posture readable without knowing Azure's implicit
behaviour — which matters when someone else is auditing the config.

**No keys in Terraform.** State stores values in plaintext. WireGuard keys
are generated on the host after boot and never enter state or this repo.

---

## Deploying

### Prerequisites

```bash
az login
az account show --query id -o tsv     # subscription id
curl -4 ifconfig.me                   # your public IP
```

### Set a budget first

Before deploying anything. Cost Management → Budgets → Create, scoped to the
subscription, amount $5, alert at 80% and 100%. This is the step people skip
and then write a blog post about their surprise bill.

### Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Tear down when not in use

```bash
terraform destroy
```

Destroying and rebuilding is the point of IaC. Do it a few times — if the
rebuild works unattended, the code is actually reproducible. If it does not,
you have found a dependency you had not noticed.

---

## WireGuard configuration

Terraform builds the host; the tunnel is configured by hand.

### On the Azure VM

```bash
ssh azureuser@<wireguard_public_ip>

sudo -i
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
cat /etc/wireguard/public.key    # give this to the on-prem peer
```

`/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address    = 172.16.0.1/30
ListenPort = 51820
PrivateKey = <azure private key>

# Masquerade so on-prem traffic can reach the workload subnet
PostUp   = iptables -t nat -A POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE

[Peer]
# on-prem
PublicKey  = <on-prem public key>
AllowedIPs = 172.16.0.2/32, 10.0.0.0/16
```

```bash
systemctl enable --now wg-quick@wg0
wg show
```

### On-prem side

```ini
[Interface]
Address    = 172.16.0.2/30
ListenPort = 51820
PrivateKey = <on-prem private key>

[Peer]
# azure
PublicKey           = <azure public key>
Endpoint            = <wireguard_public_ip>:51820
AllowedIPs          = 172.16.0.1/32, 10.10.0.0/16
PersistentKeepalive = 25
```

`PersistentKeepalive` matters here. The on-prem side sits behind three
layers of NAT (Spectrum → UDM → EdgeRouter), and without keepalives the
mappings time out and the tunnel goes quiet until traffic restarts it.

`AllowedIPs` is both a routing table and an ACL in WireGuard — a packet from
a peer is dropped unless its source falls within that peer's `AllowedIPs`.
This is a genuine conceptual difference from IPsec and a good thing to be
able to explain.

### Verifying

```bash
# from on-prem
ping 172.16.0.1                  # tunnel itself
ping <workload_private_ip>       # routing into the workload subnet

# from the Azure workload VM
ping 10.0.30.50                  # routing back to on-prem
```

Each step isolates a different layer. Tunnel up but no workload reachability
means the UDR or IP forwarding; nothing at all means the tunnel.

---

## Cost notes

| Item | Risk |
| ---- | ---- |
| B1s VMs | 750 hours/month free for 12 months — one VM's worth. Two VMs will exceed it |
| Standard public IP | Billed; no longer free |
| Log Analytics | Per-GB ingestion |
| Microsoft Sentinel | Per-GB on top of Log Analytics. Biggest sleeper cost |
| Managed disks | 64 GB free tier for 12 months |

Free-tier terms change. Verify against the current Azure free services page
rather than trusting any guide, including this one, and let the budget alert
be the real backstop.

---

## Next phases

- [ ] Inter-VLAN firewall rules on the EdgeRouter (prerequisite — the
      on-prem side has no segmentation enforcement yet)
- [ ] Bring up the tunnel and verify bidirectional routing
- [ ] Enable VNet Flow Logs and Traffic Analytics
- [ ] Onboard Microsoft Sentinel to the workspace; write KQL analytics rules
- [ ] Wazuh manager on the Proxmox host, agents on both sides
- [ ] Generate attack traffic from the ThinkCentre and tune detections
- [ ] NIST 800-53 / CIS control mapping document — what each control
      satisfies and what it does not
