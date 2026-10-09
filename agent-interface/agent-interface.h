#ifndef AGENT_INTERFACE_H
#define AGENT_INTERFACE_H

#include <stddef.h>

/* Start the embedded Python interpreter. Call once, from the main thread, before any other
 * Python call. agent_dir (e.g. the repo's agent/ folder) is put first on sys.path so its
 * modules are importable; pass NULL to skip that. On return the calling thread holds the GIL.
 * Returns 0 on success, -1 on failure with a message in err. */
int mg_python_startup(const char *agent_dir, char *err, size_t err_len);

/* Shut the interpreter down. Safe to call if startup failed or never ran.
 * Returns 0, or -1 if flushing buffered output failed. */
int mg_python_shutdown(void);

/* Load the prompt model now (seconds), so the first mg_structure_prompt() call is fast.
 * Optional: mg_structure_prompt() loads it on first use otherwise. Returns 0, or -1 with a
 * message in err. */
int mg_structure_load(char *err, size_t err_len);

/* Turn a raw user request into a JSON task spec with agent/models.py (LFM2.5-VL-3B via MLX).
 * The model loads on the first call (seconds). Needs mg_python_startup() with agent_dir set.
 * Returns a malloc'd string the caller frees, or NULL with a message in err. */
char *mg_structure_prompt(const char *prompt, char *err, size_t err_len);

#endif
