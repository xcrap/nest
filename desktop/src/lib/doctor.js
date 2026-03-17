const fixableDoctorCheckIds = [
  "php-symlink",
  "shell-path",
  "frankenphp-binary",
  "frankenphp-admin",
  "composer-runtime",
  "mariadb-runtime",
  "mariadb-ready",
  "test-resolver",
  "privileged-ports",
  "local-ca",
  "https-localhost"
];

const doctorCheckMetadata = {
  "daemon-socket": { label: "Daemon socket", area: "Control" },
  "launch-agent": { label: "Launch agent", area: "Control" },
  "php-symlink": { label: "PHP entrypoint", area: "PHP" },
  "shell-path": { label: "Shell PATH", area: "Shell" },
  "test-resolver": { label: ".test resolver", area: "Routing" },
  "privileged-ports": { label: "Ports 80 and 443", area: "Routing" },
  "https-localhost": { label: "localhost HTTPS", area: "Trust" },
  "local-ca": { label: "Local CA trust", area: "Trust" },
  "frankenphp-binary": { label: "FrankenPHP binary", area: "PHP" },
  "frankenphp-admin": { label: "FrankenPHP admin", area: "PHP" },
  "composer-runtime": { label: "Composer runtime", area: "PHP" },
  "mariadb-runtime": { label: "MariaDB runtime", area: "Data" },
  "mariadb-ready": { label: "MariaDB readiness", area: "Data" }
};

export const fixableDoctorChecks = new Set(fixableDoctorCheckIds);

export function isDoctorCheckFixable(checkId) {
  return fixableDoctorChecks.has(checkId);
}

export function doctorCheckHelpText(check) {
  if (check.status !== "pass" && isDoctorCheckFixable(check.id)) {
    return "Use Fix in Nest to repair this.";
  }
  return check.fixHint || "";
}

export function doctorCheckLabel(checkId) {
  return doctorCheckMetadata[checkId]?.label || checkId;
}

export function doctorCheckArea(checkId) {
  return doctorCheckMetadata[checkId]?.area || "Other";
}
