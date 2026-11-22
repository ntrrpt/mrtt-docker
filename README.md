## via docker compose:

```yaml
services:
  mrtt:
    container_name: mrtt
    image: mrtt:custom
    build:
      context: https://github.com/ntrrpt/mrtt-docker.git
      # args:
      #   WEB_PANEL_ANY_ADDR: 1
    ports:
      - "46000:46000/tcp"
      - "46000:46000/udp"
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ulimits:
      nproc: 65535
      nofile:
        soft: 65535
        hard: 65535
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - /home/user/.mrtt:/etc/mrtt
    environment:
      MRTT_MAIN_PASSWORD: hunter2
      MRTT_DNS: 8.8.8.8,1.1.1.1
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv6.conf.all.forwarding: "1"
      net.ipv4.conf.all.rp_filter: "2"
      net.ipv4.conf.default.rp_filter: "2"
      net.ipv4.tcp_congestion_control: "bbr"
      net.ipv4.tcp_sack: "1"
      net.ipv4.tcp_dsack: "1"
      net.ipv4.tcp_reordering: "15"
      net.ipv4.tcp_window_scaling: "1"
      net.ipv4.tcp_fastopen: "3"
      net.ipv4.tcp_slow_start_after_idle: "0"
      # net.core.default_qdisc: "fq"
    restart: unless-stopped
    stop_grace_period: 5s
    command:
      --listen 0.0.0.0:46000
```