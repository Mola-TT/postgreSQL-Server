# PostgreSQL Server - Enterprise-Grade Automated Setup

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell_Script-bashrc-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=flat&logo=postgresql&logoColor=white)](https://www.postgresql.org/)

A comprehensive, production-ready PostgreSQL server setup with **enterprise-grade security**, **automated disaster recovery**, **dynamic optimization**, and **comprehensive monitoring**. This project automates the complete deployment of a secure, high-performance PostgreSQL infrastructure with advanced threat protection and monitoring capabilities.

## 🚀 Key Features

- **🔐 Enterprise Security**: SCRAM-SHA-256 authentication, SSL/TLS encryption, firewall configuration
- **🛡️ Advanced Threat Protection**: fail2ban automated IP blocking, geographic filtering, WAF protection
- **📊 Dynamic Optimization**: Hardware-aware PostgreSQL and pgbouncer tuning
- **🔄 Disaster Recovery**: Automated service recovery, backup management, email notifications
- **📈 Comprehensive Monitoring**: Netdata integration with custom PostgreSQL dashboards and security alerts
- **🌐 Web Access**: Nginx reverse proxy with subdomain-to-database routing and security headers
- **🛠 Database Management**: Automated database creation with isolated admin users
- **🔧 User Synchronization**: Auto-sync PostgreSQL users to pgbouncer userlist
- **📧 Email Notifications**: Real-time alerts for system events, security incidents, and issues
- **🌍 Geographic Protection**: Country-based IP blocking for high-risk regions
- **⚡ DDoS Protection**: Rate limiting, request throttling, and automated attack mitigation

---

## 📋 Prerequisites

- **Ubuntu 18.04 LTS or newer** (Debian-based systems)
- **Root access** (sudo privileges)
- **Minimum 2GB RAM** (4GB+ recommended)
- **Internet connection** for package downloads
- **Domain name** (optional, for SSL certificates)

---

## ⚡ Quick Installation

```bash
# Clone the repository
git clone https://github.com/Mola-TT/postgreSQL-Server.git
cd postgreSQL-Server

# Configure your environment (IMPORTANT: Edit before installation)
nano conf/user.env

# Make scripts executable
chmod +x init.sh
chmod +x ./tools/*.sh
chmod +x ./test/*.sh

# Clear terminal and start installation
clear
sudo ./init.sh
```

---

## 🏗 Project Structure

```
postgreSQL-Server/
├── 📄 init.sh                    # Main installation script
├── 📁 setup/                     # Core setup modules
│   ├── postgresql_config.sh      # PostgreSQL installation & configuration
│   ├── nginx_config.sh           # Nginx reverse proxy setup
│   ├── netdata_config.sh         # Monitoring system setup
│   ├── backup_config.sh          # Backup system configuration
│   ├── disaster_recovery.sh      # Disaster recovery system
│   ├── dynamic_optimization.sh   # Performance optimization
│   ├── hardware_change_detector.sh # Hardware monitoring
│   ├── pg_user_monitor.sh        # User synchronization
│   ├── ssl_renewal.sh            # SSL certificate management
│   ├── security_config.sh        # Enhanced security & threat protection
│   └── general_config.sh         # General system configuration
├── 📁 tools/                     # Administrative tools
│   ├── create_database.sh        # Database creation utility
│   └── collect_log.sh            # Log collection utility
├── 📁 test/                      # Comprehensive test suites
│   ├── run_tests.sh              # Test runner
│   ├── test_pg_connection.sh     # PostgreSQL connectivity tests
│   ├── test_backup.sh            # Backup system tests
│   ├── test_disaster_recovery.sh # Disaster recovery tests
│   ├── test_netdata.sh           # Monitoring tests
│   ├── test_ssl_renewal.sh       # SSL certificate tests
│   └── [8 more specialized test files]
├── 📁 lib/                       # Shared libraries
│   ├── logger.sh                 # Logging functions
│   ├── utilities.sh              # Common utilities
│   └── pg_extract_hash.sh        # PostgreSQL password utilities
├── 📁 conf/                      # Configuration files
│   ├── default.env               # Default configuration values
│   ├── user.env.template         # User configuration template
│   └── user.env                  # Your custom configuration
└── 📁 .cursor/                   # Development guidelines
    └── rules/                    # Project milestones and rules
```

---

## ⚙️ Configuration

### 🔧 Essential Configuration (conf/user.env)

**Before installation**, copy the template and customize your settings:

```bash
cp conf/user.env.template conf/user.env
nano conf/user.env
```

### 🔑 Critical Settings to Configure:

```bash
# PostgreSQL Configuration
PG_SUPERUSER_PASSWORD="your-secure-password-here"
PG_DATABASE="your_database_name"

# Domain & SSL (for production)
NGINX_DOMAIN="yourdomain.com"
SSL_EMAIL="admin@yourdomain.com"
PRODUCTION=true

# Email Notifications
EMAIL_SENDER="postgres@yourdomain.com"
EMAIL_RECIPIENT="admin@yourdomain.com"
SMTP_SERVER="smtp.yourdomain.com"
SMTP_USERNAME="your-smtp-user"
SMTP_PASSWORD="your-smtp-password"

# Security Configuration
SECURITY_EMAIL="security@yourdomain.com"
GEOIP_BLOCKED_COUNTRIES="CN RU KP IR"
FAIL2BAN_WHITELIST_IPS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

# Monitoring Access
NETDATA_ADMIN_USER="admin"
NETDATA_ADMIN_PASSWORD="secure-monitoring-password"
```

---

## 📍 Important File Locations

### 📊 **Logs**
```bash
# Main installation log
/var/log/server_init.log

# Service-specific logs
/var/log/pg-user-monitor.log        # User sync monitoring
/var/log/disaster-recovery.log      # Disaster recovery events
/var/log/letsencrypt-renewal.log    # SSL certificate renewal
/var/log/security-monitor.log       # Security monitoring and alerts
/var/log/msmtp.log                  # Email sending logs

# PostgreSQL logs
/var/log/postgresql/               # PostgreSQL server logs
/var/log/pgbouncer/               # Connection pooler logs
/var/log/nginx/                   # Web server logs
/var/log/netdata/                 # Monitoring system logs
/var/log/fail2ban.log             # Security blocking events
```

### 💾 **Backups**
```bash
# Backup storage location
/var/lib/postgresql/backups/       # Main backup directory
├── daily/                         # Daily incremental backups
├── weekly/                        # Weekly full backups
├── monthly/                       # Monthly archive backups
└── verification/                  # Backup verification logs

# Backup configuration
/etc/cron.d/postgresql-backup      # Backup scheduling
```

### 🔧 **Configuration Files**
```bash
# PostgreSQL configuration
/etc/postgresql/*/main/postgresql.conf           # Main PostgreSQL config
/etc/postgresql/*/main/pg_hba.conf              # Authentication config
/etc/postgresql/*/main/conf.d/90-dynamic-optimization.conf  # Auto-tuning

# pgbouncer configuration
/etc/pgbouncer/pgbouncer.ini       # Connection pooler config
/etc/pgbouncer/userlist.txt        # User authentication (auto-managed)

# Nginx configuration
/etc/nginx/sites-available/postgresql          # PostgreSQL proxy config
/etc/nginx/sites-available/netdata.conf       # Monitoring proxy config
/etc/nginx/conf.d/security.conf               # Security headers and WAF rules
/etc/nginx/snippets/security-headers.conf     # Security header snippets
/etc/nginx/snippets/block-exploits.conf       # Exploit blocking rules

# Security configuration
/etc/fail2ban/jail.d/postgresql-server.conf   # fail2ban jail configuration
/etc/fail2ban/filter.d/nginx-*.conf          # Custom nginx filters
/etc/fail2ban/filter.d/postgresql-auth.conf  # PostgreSQL auth filter
/usr/local/bin/geoip-block.sh                # Geographic blocking script
/usr/local/bin/security-monitor.sh           # Security monitoring script

# SSL certificates
/etc/letsencrypt/live/yourdomain.com/         # Let's Encrypt certificates
/etc/nginx/ssl/                               # Self-signed certificates (fallback)

# Monitoring configuration
/etc/netdata/netdata.conf          # Netdata main config
/etc/netdata/health.d/             # Custom health checks
```

### 📈 **Monitoring & State Files**
```bash
# Hardware and optimization
/var/lib/postgresql/hardware_specs.json        # Hardware specifications
/var/lib/postgresql/optimization_reports/      # Performance reports
/var/lib/postgresql/config_backups/           # Configuration backups

# Service state management
/var/lib/postgresql/user_monitor_state.json    # User sync state
/var/lib/postgresql/disaster_recovery_state.json  # Recovery events

# SSL certificate storage
/etc/letsencrypt/                  # Let's Encrypt certificates and config
```

### 🏃‍♂️ **Service Files**
```bash
# Systemd services
/etc/systemd/system/pg-user-monitor.service    # User monitoring service
/etc/systemd/system/disaster-recovery.service  # Disaster recovery service
/etc/systemd/system/pg-full-optimization.timer # Hardware change optimization
/etc/systemd/system/geoip-block.service        # Geographic IP blocking service

# Cron jobs
/etc/cron.d/postgresql-backup      # Backup scheduling
/etc/cron.d/ssl-renewal-reminder   # SSL renewal reminders
/etc/cron.d/certbot               # Let's Encrypt renewal
/etc/cron.d/security-monitor      # Security monitoring cron job
```

---

## 🔗 Access Points

After successful installation:

### 🗄️ **Database Access**
```bash
# Direct PostgreSQL (local only)
psql -h localhost -p 5432 -U postgres -d your_database

# Through pgbouncer (recommended)
psql -h localhost -p 6432 -U postgres -d your_database

# Web-based access (if domain configured)
https://yourdatabase.yourdomain.com/
```

### 📊 **Monitoring Dashboard**
```bash
# Local access
https://localhost/netdata/

# Domain access (if configured)
https://monitor.yourdomain.com/
# Credentials: admin / your-netdata-password
```

### 🔧 **Administrative Tools**
```bash
# Create new database with isolated admin
sudo ./tools/create_database.sh

# Collect system logs for troubleshooting
sudo ./tools/collect_log.sh

# Run comprehensive tests
sudo ./test/run_tests.sh
```

---

## 🛠 Management Commands

### 📊 **Service Management**
```bash
# Check all services status
systemctl status postgresql pgbouncer nginx netdata fail2ban

# Restart services
sudo systemctl restart postgresql
sudo systemctl restart pgbouncer
sudo systemctl restart nginx
sudo systemctl restart fail2ban

# View logs
sudo journalctl -u postgresql -f
sudo journalctl -u disaster-recovery -f
sudo journalctl -u fail2ban -f

# Security management
sudo fail2ban-client status                    # Check fail2ban status
sudo fail2ban-client status nginx-limit-req   # Check specific jail
sudo fail2ban-client unban <IP>               # Unban an IP address
```

### 💾 **Backup Management**
```bash
# Manual backup
sudo -u postgres pg_dump -h localhost -p 5432 your_database > backup.sql

# List automatic backups
ls -la /var/lib/postgresql/backups/

# Restore from backup
sudo -u postgres psql -h localhost -p 5432 your_database < backup.sql
```

### 🔧 **Performance Tuning**
```bash
# Trigger immediate optimization
sudo /path/to/setup/dynamic_optimization.sh

# View optimization reports
ls -la /var/lib/postgresql/optimization_reports/

# Check hardware specifications
cat /var/lib/postgresql/hardware_specs.json
```

---

## 🧪 Testing

Run comprehensive tests to validate your installation:

```bash
# Run all tests
sudo ./test/run_tests.sh

# Run specific test suites
sudo ./test/test_pg_connection.sh      # Database connectivity
sudo ./test/test_backup.sh             # Backup system
sudo ./test/test_disaster_recovery.sh  # Recovery procedures
sudo ./test/test_netdata.sh            # Monitoring system
sudo ./test/test_ssl_renewal.sh        # SSL certificates
```

---

## 🚨 Troubleshooting

### 📋 **Common Issues**

**PostgreSQL won't start:**
```bash
sudo systemctl status postgresql
sudo journalctl -u postgresql -n 50
```

**pgbouncer authentication issues:**
```bash
# Check userlist synchronization
sudo systemctl status pg-user-monitor
sudo tail -f /var/log/pg-user-monitor.log
```

**SSL certificate problems:**
```bash
# Check SSL renewal status
sudo ./test/test_ssl_renewal.sh
sudo tail -f /var/log/letsencrypt-renewal.log
```

**Email notifications not working:**
```bash
# Test email configuration
sudo ./test/test_email_notification.sh
sudo tail -f /var/log/msmtp.log
```

**Security issues or suspicious activity:**
```bash
# Check security monitoring logs
sudo tail -f /var/log/security-monitor.log

# Review fail2ban activity
sudo fail2ban-client status
sudo tail -f /var/log/fail2ban.log

# Check nginx security logs
sudo tail -f /var/log/nginx/error.log | grep -E "(limit_req|444)"
```

### 🔧 **Log Collection**
```bash
# Collect all relevant logs for support
sudo ./tools/collect_log.sh
# Creates: /tmp/postgresql_server_logs_YYYYMMDD_HHMMSS.tar.gz
```

---

## 🔄 Updates and Maintenance

### 🆕 **Updating the Setup**
```bash
# Pull latest changes
git pull origin main

# Re-run specific setup modules (if needed)
sudo ./setup/dynamic_optimization.sh
sudo ./setup/ssl_renewal.sh
```

### 🧹 **Maintenance Tasks**
- **Daily**: Automatic backups and health checks
- **Weekly**: Full backup creation and verification
- **Monthly**: SSL certificate renewal check
- **As needed**: Hardware optimization after changes

---

## 📚 Documentation

- **Milestone Tracking**: `.cursor/rules/001. milestone.mdc`
- **Configuration Reference**: `conf/user.env.template`
- **Test Coverage**: Individual test files in `test/` directory
- **Service Logs**: Various locations documented above

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

## 🙏 Acknowledgments

- PostgreSQL Development Team
- Nginx Team
- Netdata Team
- Let's Encrypt / Certbot
- Ubuntu/Debian Communities

---

## 📞 Support

For issues and questions:
- **GitHub Issues**: [Create an Issue](https://github.com/Mola-TT/postgreSQL-Server/issues)
- **Documentation**: Check this README and inline script comments
- **Logs**: Use `./tools/collect_log.sh` for comprehensive log collection

---