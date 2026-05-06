#!/bin/sh

write_native_pam_client_c() {
    output="$1"
    cat > "$output" <<'EOF'
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int smoke_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
  (void)appdata_ptr;
  struct pam_response *responses = calloc((size_t)num_msg, sizeof(struct pam_response));
  if (responses == NULL) {
    return PAM_BUF_ERR;
  }
  for (int i = 0; i < num_msg; i++) {
    switch (msg[i]->msg_style) {
    case PAM_PROMPT_ECHO_OFF:
    case PAM_PROMPT_ECHO_ON:
      responses[i].resp = strdup(candidate);
      if (responses[i].resp == NULL) {
        free(responses);
        return PAM_BUF_ERR;
      }
      break;
    case PAM_TEXT_INFO:
    case PAM_ERROR_MSG:
      if (msg[i]->msg != NULL) {
        fprintf(stderr, "pam_message[%d]=%s\n", msg[i]->msg_style, msg[i]->msg);
      }
      responses[i].resp = NULL;
      break;
    default:
      free(responses);
      return PAM_CONV_ERR;
    }
  }
  *resp = responses;
  return PAM_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s <service> <user> <password>\n", argv[0]);
    return 2;
  }
  candidate = argv[3];
  struct pam_conv conv = {smoke_conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start(argv[1], argv[2], &conv, &pamh);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_start: %s\n", pam_strerror(pamh, rc));
    return 2;
  }
  rc = pam_chauthtok(pamh, PAM_SILENT);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_chauthtok: %s\n", pam_strerror(pamh, rc));
  }
  int end_rc = pam_end(pamh, rc);
  if (end_rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_end: %d\n", end_rc);
    return 2;
  }
  return rc == PAM_SUCCESS ? 0 : 1;
}
EOF
}

write_native_pam_authtok_module_c() {
    output="$1"
    env_name="$2"
    cat > "$output" <<EOF
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdlib.h>

PAM_EXTERN int pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)argc;
  (void)argv;
  if ((flags & PAM_PRELIM_CHECK) != 0) {
    return PAM_SUCCESS;
  }
  if ((flags & PAM_UPDATE_AUTHTOK) == 0) {
    return PAM_IGNORE;
  }
  const char *token = getenv("$env_name");
  if (token == NULL) {
    return PAM_AUTHTOK_ERR;
  }
  return pam_set_item(pamh, PAM_AUTHTOK, token);
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
EOF
}
