# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DEPLOY A CLOUD SQL CLUSTER
# This module deploys a Cloud SQL MySQL cluster. The cluster is managed by Google and automatically handles leader
# election, replication, failover, backups, patching, and encryption.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ------------------------------------------------------------------------------
# PREPARE LOCALS
#
# NOTE: Due to limitations in terraform and heavy use of nested sub-blocks in the resource,
# we have to construct some of the configuration values dynamically
# ------------------------------------------------------------------------------

locals {
  # Determine the engine type
  is_postgres = "${replace(var.engine, "POSTGRES", "") != var.engine}"
  is_mysql    = "${replace(var.engine, "MYSQL", "") != var.engine}"

  # Calculate actuals, so we get expected behavior for each engine
  actual_binary_log_enabled     = "${local.is_postgres ? false : var.mysql_binary_log_enabled}"
  actual_availability_type      = "${local.is_postgres && var.enable_failover_replica ? "REGIONAL" : "ZONAL"}"
  actual_failover_replica_count = "${local.is_postgres ? 0 : var.enable_failover_replica ? 1 : 0}"
}

# ------------------------------------------------------------------------------
# CREATE THE MASTER INSTANCE
#
# NOTE: We have multiple google_sql_database_instance resources, based on
# HA and replication configuration options.
# ------------------------------------------------------------------------------

resource "google_sql_database_instance" "master" {
  depends_on = ["null_resource.dependency_getter"]

  provider         = "google"
  name             = "${var.name}"
  project          = "${var.project}"
  region           = "${var.region}"
  database_version = "${var.engine}"

  settings {
    tier                        = "${var.machine_type}"
    activation_policy           = "${var.activation_policy}"
    authorized_gae_applications = "${var.authorized_gae_applications}"
    disk_autoresize             = "${var.disk_autoresize}"

    ip_configuration {
      # authorized_networks = []
      ipv4_enabled    = "${var.enable_public_internet_access}"
      private_network = "${var.private_network}"
      require_ssl     = "${var.require_ssl}"
    }

    location_preference {
      follow_gae_application = "${var.follow_gae_application}"
      zone                   = "${var.master_zone}"
    }

    backup_configuration {
      binary_log_enabled = "${local.actual_binary_log_enabled}"
      enabled            = "${var.backup_enabled}"
      start_time         = "${var.backup_start_time}"
    }

    maintenance_window {
      day          = "${var.maintenance_window_day}"
      hour         = "${var.maintenance_window_hour}"
      update_track = "${var.maintenance_track}"
    }

    disk_size = "${var.disk_size}"
    disk_type = "${var.disk_type}"
    # database_flags    = "${var.database_flags}"
    availability_type = "${local.actual_availability_type}"

    user_labels = "${var.custom_labels}"
  }

  # Default timeouts are 10 minutes, which in most cases should be enough.
  # Sometimes the database creation can, however, take longer, so we
  # increase the timeouts slightly.
  timeouts {
    create = "${var.resource_timeout}"
    delete = "${var.resource_timeout}"
    update = "${var.resource_timeout}"
  }
}

# ------------------------------------------------------------------------------
# CREATE A DATABASE
# ------------------------------------------------------------------------------

resource "google_sql_database" "default" {
  depends_on = ["google_sql_database_instance.master"]

  name      = "${var.db_name}"
  project   = "${var.project}"
  instance  = "${google_sql_database_instance.master.name}"
  charset   = "${var.db_charset}"
  collation = "${var.db_collation}"
}

resource "google_sql_user" "default" {
  depends_on = ["google_sql_database.default"]

  name     = "${var.master_user_name}"
  project  = "${var.project}"
  instance = "${google_sql_database_instance.master.name}"
  host     = "${var.master_user_host}"
  password = "${var.master_user_password}"
}

# ------------------------------------------------------------------------------
# SET MODULE DEPENDENCY RESOURCE
# This works around a terraform limitation where we can not specify module dependencies natively.
# See https://github.com/hashicorp/terraform/issues/1178 for more discussion.
# By resolving and computing the dependencies list, we are able to make all the resources in this module depend on the
# resources backing the values in the dependencies list.
# ------------------------------------------------------------------------------

resource "null_resource" "dependency_getter" {
  provisioner "local-exec" {
    command = "echo ${length(var.dependencies)}"
  }
}

# ------------------------------------------------------------------------------
# CREATE THE FAILOVER REPLICA
# ------------------------------------------------------------------------------

resource "google_sql_database_instance" "failover_replica" {
  count = "${local.actual_failover_replica_count}"

  depends_on = [
    "google_sql_database_instance.master",
    "google_sql_database.default",
    "google_sql_user.default",
  ]

  provider         = "google"
  name             = "${var.name}-failover"
  project          = "${var.project}"
  region           = "${var.region}"
  database_version = "${var.engine}"

  # The name of the instance that will act as the master in the replication setup.
  master_instance_name = "${google_sql_database_instance.master.name}"

  replica_configuration {
    # Specifies that the replica is the failover target.
    failover_target = true
  }

  settings {
    crash_safe_replication = true

    tier                        = "${var.machine_type}"
    authorized_gae_applications = "${var.authorized_gae_applications}"
    disk_autoresize             = "${var.disk_autoresize}"

    ip_configuration {
      # authorized_networks = "${var.authorized_networks}"
      ipv4_enabled    = "${var.enable_public_internet_access}"
      private_network = "${var.private_network}"
      require_ssl     = "${var.require_ssl}"
    }

    location_preference {
      follow_gae_application = "${var.follow_gae_application}"
      zone                   = "${var.mysql_failover_replica_zone}"
    }

    disk_size = "${var.disk_size}"
    disk_type = "${var.disk_type}"
    # database_flags = "${var.database_flags}"

    user_labels = "${var.custom_labels}"
  }

  # Default timeouts are 10 minutes, which in most cases should be enough.
  # Sometimes the database creation can, however, take longer, so we
  # increase the timeouts slightly.
  timeouts {
    create = "${var.resource_timeout}"
    delete = "${var.resource_timeout}"
    update = "${var.resource_timeout}"
  }
}

# ------------------------------------------------------------------------------
# CREATE THE READ REPLICAS
# ------------------------------------------------------------------------------

resource "google_sql_database_instance" "read_replica" {
  count = "${var.num_read_replicas}"

  depends_on = [
    "google_sql_database_instance.master",
    "google_sql_database_instance.failover_replica",
    "google_sql_database.default",
    "google_sql_user.default",
  ]

  provider         = "google"
  name             = "${var.name}-read-${count.index}"
  project          = "${var.project}"
  region           = "${var.region}"
  database_version = "${var.engine}"

  # The name of the instance that will act as the master in the replication setup.
  master_instance_name = "${google_sql_database_instance.master.name}"

  replica_configuration {
    # Specifies that the replica is not the failover target.
    failover_target = false
  }

  settings {
    tier                        = "${var.machine_type}"
    authorized_gae_applications = "${var.authorized_gae_applications}"
    disk_autoresize             = "${var.disk_autoresize}"

    ip_configuration {
      # authorized_networks = "${var.authorized_networks}"
      ipv4_enabled    = "${var.enable_public_internet_access}"
      private_network = "${var.private_network}"
      require_ssl     = "${var.require_ssl}"
    }

    location_preference {
      follow_gae_application = "${var.follow_gae_application}"
      zone                   = "${element(var.read_replica_zones, count.index)}"
    }

    disk_size = "${var.disk_size}"
    disk_type = "${var.disk_type}"
    # database_flags = "${var.database_flags}"

    user_labels = "${var.custom_labels}"
  }

  # Read replica creation is initiated concurrently, but the provider creates
  # the resources sequentially. Therefore we increase the timeouts considerably
  # to allow successful creation of multiple read replicas without having to
  # fear the operation timing out.
  timeouts {
    create = "${var.resource_timeout}"
    delete = "${var.resource_timeout}"
    update = "${var.resource_timeout}"
  }
}

# ------------------------------------------------------------------------------
# CREATE A TEMPLATE FILE TO SIGNAL ALL RESOURCES HAVE BEEN CREATED
# ------------------------------------------------------------------------------
data "template_file" "complete" {
  depends_on = [
    "google_sql_database_instance.master",
    "google_sql_database_instance.failover_replica",
    "google_sql_database_instance.read_replica",
    "google_sql_database.default",
    "google_sql_user.default",
  ]

  template = "true"
}
