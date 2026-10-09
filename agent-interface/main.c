#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "screen_capture.h"
#include "agent-interface.h"
#include <assert.h>
int image_capture(void)
{
	int ret = 0; 
	if(mg_capture_permission()){
		ret = mg_capture_request_permission();
	}
	return ret;
}
int main(void)
{
	int perms = image_capture();
	assert(perms == 1);
	char err[512];
	if (mg_python_startup(MG_AGENT_DIR, err, sizeof err) != 0) {
		fprintf(stderr, "%s\n", err);
		return 1;
	}
	/* Load the model before the first request arrives, not during it. A failure here isn't
	 * fatal: each request retries and reports the error itself. */
	if (mg_structure_load(err, sizeof err) != 0)
		fprintf(stderr, "%s\n", err);

	char * chunks = NULL; 
	size_t len = 0;
	ssize_t nread; 
	while ((nread = getline(&chunks, &len, stdin)) != -1) {
		if (nread > 0 && chunks[nread - 1] == '\n')
			chunks[--nread] = '\0';
		if (strncmp(chunks, "prompt ", 7) != 0)
			continue;
		char *spec = mg_structure_prompt(chunks + 7, err, sizeof err);
		fprintf(stderr, "%s\n", spec ? spec : err);
		/* The overlay keeps this process for the next request: exactly one final status
		 * per prompt tells it this one is finished. */
		printf("{\"type\":\"status\",\"state\":\"%s\"}\n", spec ? "done" : "error");
		fflush(stdout);
		free(spec);
	}
	free(chunks);

	mg_python_shutdown();
	return 0;
}
