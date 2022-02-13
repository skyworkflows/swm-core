#include "exitcodes.h"
#include "wm_entity.h"
#include "wm_io.h"
#include "wm_job.h"
#include "wm_process.h"
#include "wm_entity_utils.h"
#include "wm_porter_data.h"

#include <ei.h>

#include <cerrno>
#include <cstring>
#include <iostream>
#include <fstream>
#include <fcntl.h>
#include <getopt.h>
#include <linux/limits.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHILD_WAITING_TIME 5
#define PROCESS_TUPLE_SIZE 6

using namespace swm;

void set_uid_gid(uid_t uid, uid_t gid) {
  int status = -1;
  status = setregid(gid, gid);
  if (status < 0) {
    swm_loge("Couldn't set gid, status=", status);
    exit(status);
  }
  status = setreuid(uid, uid);
  if (status < 0) {
    swm_loge("Couldn't set uid, status=", status);
    exit(status);
  }
}

void set_workdir(passwd *pw, SwmJob &job) {
  auto workdir = job.get_workdir();
  if (workdir.empty()) {
    workdir = pw->pw_dir;
  }
  chdir(workdir.c_str());
  swm_logi("Job working directory: %s", workdir.c_str());
}

void switch_stdout(const std::string &path) {
  FILE *outfile = fopen(path.c_str(), "w");
  if (!outfile) {
    swm_loge("Can't open %s", path.c_str());
    exit(EXIT_FILE_ERROR);
  }
  if (dup2(fileno(outfile), STDOUT_FILENO) < 0) {
    swm_loge("Can't duplicate out file descriptor for %s: %s", path.c_str(), std::strerror(errno));
    exit(EXIT_SYSTEM_ERROR);
  }
  fclose(outfile);
}

void switch_stderr(const std::string &path) {
  FILE *errfile = fopen(path.c_str(), "w");
  if (!errfile) {
    swm_loge("Can't open %s", path.c_str());
    exit(EXIT_FILE_ERROR);
  }
  if (dup2(fileno(errfile), STDERR_FILENO) < 0) {
    swm_loge("Can't duplicate err file descriptor for %s: %s", path.c_str(), std::strerror(errno));
    exit(EXIT_SYSTEM_ERROR);
  }
  fclose(errfile);
}

void set_io(const SwmJob &job) {
  swm_logd("Set IO");
  auto out_path = job.get_job_stdout();
  static std::string token = "%j";
  const auto id = job.get_id();
  const size_t len = std::string("%j").size();
  if (out_path.size()) {
    const size_t pos = out_path.find(token);
    if (pos != std::string::npos) {
      out_path.replace(pos, len, id);
    }
    swm_logi("Job stdout: %s", out_path.c_str());
    switch_stdout(out_path);
  }

  auto err_path = job.get_job_stderr();
  if (err_path.size()) {
    const size_t pos = err_path.find(token);
    if (pos != std::string::npos) {
      err_path.replace(pos, len, id);
    }
    swm_logi("Job stderr: %s", err_path.c_str());
    switch_stderr(err_path);
  }
}

void print_usage(const std::string &prog) {
  std::cout << "Usage: " << prog << " [-d|-h]" << std::endl;
}

void parse_opts(int argc, char* const argv[]) {
  const char* short_opts = "hd";
  const option long_opts[] = {
    {"help", no_argument, nullptr, 'h'},
    {"debug", no_argument, nullptr, 'd'},
    {nullptr, 0, nullptr, 0}
  };

  int res;
  int opt_idx;
  int log_level = SWM_LOG_LEVEL_INFO;
  while((res=getopt_long(argc, argv, short_opts, long_opts, &opt_idx)) != -1) {
    switch(res) {
      case 'h': {
        print_usage(argv[0]);
        exit(0);
      };
      case 'd': {
        log_level = SWM_LOG_LEVEL_DEBUG1;
      };
      default: {
      }
    }
  }
  swm_log_init(log_level, stderr);
}

void set_env(passwd *pw, const SwmJob &job) {
  const std::string cwd = job.get_workdir();
  setenv("HOME", pw->pw_dir, 1);
  setenv("USER", pw->pw_name, 1);
  setenv("SWM_JOB_ID", job.get_id().c_str(), 1);
  if (cwd.size()) {
    const std::string path = job.get_workdir() + ":" + getenv("PATH");
    const auto path_str = path.c_str();
    setenv("PATH", path_str, 1);
    setenv("PWD", path_str, 1);
    swm_logi("Job PATH=%s", path_str);
  }
}

int send_process_info(const SwmProcess &proc) {
  ETERM* props[PROCESS_TUPLE_SIZE];
  props[0] = erl_mk_atom("process");
  props[1] = erl_mk_int(proc.get_pid());
  props[2] = erl_mk_string(proc.get_state().c_str());
  props[3] = erl_mk_int(proc.get_exitcode());
  props[4] = erl_mk_int(proc.get_signal());
  props[5] = erl_mk_string(proc.get_comment().c_str());
  ETERM* eproc =erl_mk_tuple(props, PROCESS_TUPLE_SIZE);
  if (swm_get_log_level() >= SWM_LOG_LEVEL_DEBUG1) {
    swm_logd("Process eterm: ", eproc);
    //erl_print_term(stderr, eproc);
  }

  byte *buf = (byte*)malloc(erl_term_len(eproc));
  size_t bufbytes = erl_encode(eproc, buf);

  if (!bufbytes) {
    swm_loge("Can not encode ETERM");
    return -1;
  }

  swm_write_exact(&std::cout, buf, bufbytes);
  erl_free_compound(eproc);
  free(buf);
  fflush(stdout);

  swm_logd("Process info has been just sent to stdout (%s)", proc.get_state().c_str());
  return 0;
}

std::string save_script(const std::string &job_id, const uid_t uid, const gid_t gid, const std::string &content) {
  const std::string path = "/tmp/swm-" + job_id + ".sh";
  std::ofstream file(path, std::ofstream::out);
  if (!file.is_open()) {
    const auto msg = "Error creating script file: " + path;
    std::perror(msg.c_str());
    exit(EXIT_FAILURE);
  }
  file << content;
  file.close();

  if (chmod(path.c_str(), S_IRWXU) != 0) {
    const auto msg = "Could not set permissions to " + path;
    std::perror(msg.c_str());
    exit(EXIT_FAILURE);
  }

  if (chown(path.c_str(), uid, gid) == -1) {
    const auto msg = "Could not set ownership to " + path;
    std::perror(msg.c_str());
    exit(EXIT_FAILURE);
  }

  return path;
}

int main(int argc, char* const argv[]) {
  // Fix docker issue: exec does not wait for its command completion
  // thus user creation and send to porter started at the same time.
  sleep(2);

  swm_logd("Porter has started");

  parse_opts(argc, argv);
  ei_init();

  byte* data[SWM_DATA_TYPES_COUNT];
  if (get_porter_data(&std::cin, data)) {
    swm_loge("Could not read raw input data");
    return EXIT_FAILURE;
  }

  SwmProcInfo info;
  if (parse_data(data, info)) {
    swm_loge("Could not decode data");
    return EXIT_FAILURE;
  }

  pid_t child_pid;

  if ((child_pid = fork()) == -1) {
    swm_loge("Fork error!");
    exit(EXIT_FAILURE);
  } else if (child_pid == 0) { /* This is the child */
    swm_logi("Job process started");

    const auto username = info.user.get_name().c_str();
    swm_logi("User: \"%s\"", username);

    size_t counter = 0;
    const uint64_t max_attempts = 20;
    passwd *pw = nullptr;
    while ((pw = getpwnam(username)) == nullptr) {
      if (++counter >= max_attempts) {
        swm_logd("User \"%s\" not found => exit", username);
        exit(EXIT_USER_NOT_FOUND);
      }
      swm_logd("User \"%s\" not found (yet) => wait and repeat", username);
      sleep(1);
    };
    swm_logd("User found: uid=%d gid=%d", pw->pw_uid, pw->pw_gid);

    const auto content = info.job.get_script_content();
    const auto job_id = info.job.get_id();
    const auto path = save_script(job_id, pw->pw_uid, pw->pw_gid, content);
    swm_logi("Temporary execution path: \"%s\"", path.c_str());

    set_uid_gid(pw->pw_uid, pw->pw_gid);
    set_env(pw, info.job);
    set_workdir(pw, info.job);

    set_io(info.job);  // do not use logger after this point

    extern char** environ;
    char* const argv[] = {
      const_cast<char*>("/bin/sh"),
      const_cast<char*>("-c"),
      const_cast<char*>(path.c_str()),
      nullptr
    };
    execve("/bin/sh", &argv[0], environ);

  } else {  /* This is the parent */
    swm_logi("Parent process started, job process pid=%d", child_pid);

    int status;

    while(1) {
      pid_t end_pid = waitpid(child_pid, &status, WNOHANG|WUNTRACED);
      SwmProcess proc;
      proc.set_pid(child_pid);
      proc.set_state(SWM_JOB_STATE_ERROR);
      proc.set_exitcode(-1);
      proc.set_signal(-1);

      swm_logd("Child end_pid: %d (status=%d)", end_pid, status);
      if (end_pid == -1) { /*  error calling waitpid */
        swm_loge("waitpid error");
        proc.set_comment("waitpid error");
        if (send_process_info(proc)) {
          swm_loge("Process info not sent");
          return EXIT_FAILURE;
        }
        sleep(CHILD_WAITING_TIME); // give container time to propagate the final info to swm
        exit(EXIT_FAILURE);
      } else if (end_pid == 0) { /* child still running  */
        //swm_logd("Parent process started waiting for child");
        proc.set_state(SWM_JOB_STATE_RUNNING);
        if (send_process_info(proc)) {
          swm_loge("Child process info not sent");
          return EXIT_FAILURE;
        }
        sleep(CHILD_WAITING_TIME);
      } else if (end_pid == child_pid) { /* child ended */
        int exitcode = -1;
        int sig = 0;
        if (WIFEXITED(status)) {
          exitcode = WEXITSTATUS(status);
          if (status == 0) {
            swm_logi("Job process has terminated normally", exitcode);
          } else {
            swm_loge("Job process has terminated with exit code",  exitcode);
          }
        }
        if (WIFSIGNALED(status)) {
          sig = WTERMSIG(status);
          const char *strsig = strsignal(sig);
          swm_loge("Job process has terminated by uncaught signal \"%s\"", strsig);
          if (WCOREDUMP(status)) {
            swm_logi("Job process has produced a core dump");
          }
        }
        if (WIFSTOPPED(status)) {
          sig = WSTOPSIG(status);
          const char *strsig = strsignal(sig);
          swm_loge("Job process has been stopped by delivery of a signal \"%s\"", strsig);
        }
        proc.set_state( SWM_JOB_STATE_FINISHED);
        proc.set_exitcode(exitcode);
        proc.set_signal(sig);
        if (send_process_info(proc)) {
          swm_loge("The final job process info has not been sent");
          return EXIT_FAILURE;
        }
        sleep(CHILD_WAITING_TIME); // give container time to propagate the final info to swm
        break;
      }
    }
    wait(&status);
  }

  return EXIT_SUCCESS;
}
