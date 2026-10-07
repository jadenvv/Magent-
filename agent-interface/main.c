#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int main(void)
{
	char * chunks = NULL; 
	size_t len = 0;
	ssize_t nread; 

	nread = getline(&chunks, &len, stdin); 
	if (nread != -1)
	{
		printf("reading: %s", chunks);
	}
	free(chunks);

	return 0;
}
