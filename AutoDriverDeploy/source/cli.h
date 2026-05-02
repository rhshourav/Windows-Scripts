#ifndef CLI_H
#define CLI_H

void SaveHWID(wchar_t *hwid);
void Parse_save_installed_id_swith(const wchar_t *ParamStr);
void Parse_HWID_installed_swith(const wchar_t *ParamStr);

void init_CLIParam();
void RUN_CLI();

#endif
