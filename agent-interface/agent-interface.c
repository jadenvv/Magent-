#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "agent-interface.h"

static void set_err(char *err, size_t err_len, const char *what, const char *detail)
{
	if (err && err_len)
		snprintf(err, err_len, "%s%s%s", what, detail ? ": " : "", detail ? detail : "");
}

int mg_python_startup(const char *agent_dir, char *err, size_t err_len)
{
	if (Py_IsInitialized()) {
		set_err(err, err_len, "python already initialized", NULL);
		return -1;
	}

	/* Isolated: ignore PYTHON* env vars, user site-packages, and the current directory, so
	 * what gets imported doesn't depend on the shell the agent was launched from. */
	PyConfig config;
	PyConfig_InitIsolatedConfig(&config);
	/* Leave SIGINT to C. If Python installed its handler, Ctrl-C would only set a flag that
	 * Python checks when it's running, and wouldn't stop the agent while C code is running. */
	config.install_signal_handlers = 0;

	PyStatus status = Py_InitializeFromConfig(&config);
	PyConfig_Clear(&config);
	if (PyStatus_Exception(status)) {
		set_err(err, err_len, "python init failed", status.err_msg);
		return -1;
	}

	if (agent_dir) {
		PyObject *sys_path = PySys_GetObject("path"); /* borrowed */
		PyObject *dir = PyUnicode_DecodeFSDefault(agent_dir);
		int ok = sys_path && dir && PyList_Insert(sys_path, 0, dir) == 0;
		Py_XDECREF(dir);
		if (!ok) {
			PyErr_Clear();
			set_err(err, err_len, "can't add to sys.path", agent_dir);
			Py_FinalizeEx();
			return -1;
		}
	}
	return 0;
}

int mg_python_shutdown(void)
{
	if (!Py_IsInitialized())
		return 0;
	return Py_FinalizeEx() < 0 ? -1 : 0;
}

/* Puts the pending Python exception's text in err and clears it. */
static void set_py_err(char *err, size_t err_len, const char *what)
{
	PyObject *exc = PyErr_GetRaisedException();
	PyObject *msg = exc ? PyObject_Str(exc) : NULL;
	const char *text = msg ? PyUnicode_AsUTF8(msg) : NULL;
	set_err(err, err_len, what, text);
	Py_XDECREF(msg);
	Py_XDECREF(exc);
	PyErr_Clear();
}

/* models.<name>, imported once. NULL with a message in err on failure. */
static PyObject *models_func(const char *name, char *err, size_t err_len)
{
	static PyObject *models;

	if (!Py_IsInitialized()) {
		set_err(err, err_len, "python not initialized", NULL);
		return NULL;
	}
	if (!models && !(models = PyImport_ImportModule("models"))) {
		set_py_err(err, err_len, "can't import models");
		return NULL;
	}
	PyObject *f = PyObject_GetAttrString(models, name);
	if (!f)
		set_py_err(err, err_len, name);
	return f;
}

int mg_structure_load(char *err, size_t err_len)
{
	PyObject *load = models_func("load", err, err_len);
	if (!load)
		return -1;
	PyObject *r = PyObject_CallNoArgs(load);
	Py_DECREF(load);
	if (!r) {
		set_py_err(err, err_len, "loading the prompt model failed");
		return -1;
	}
	Py_DECREF(r);
	return 0;
}

char *mg_structure_prompt(const char *prompt, char *err, size_t err_len)
{
	PyObject *structure_prompt = models_func("structure_prompt", err, err_len);
	if (!structure_prompt)
		return NULL;

	PyObject *result = PyObject_CallFunction(structure_prompt, "s", prompt);
	Py_DECREF(structure_prompt);
	if (!result) {
		set_py_err(err, err_len, "structure_prompt failed");
		return NULL;
	}
	const char *json = PyUnicode_AsUTF8(result);
	char *out = json ? strdup(json) : NULL;
	if (!json)
		set_py_err(err, err_len, "structure_prompt returned a non-string");
	else if (!out)
		set_err(err, err_len, "out of memory", NULL);
	Py_DECREF(result);
	return out;
}
