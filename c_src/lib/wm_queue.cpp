#include "wm_entity_utils.h"

#include <iostream>

#include "wm_queue.h"

#include <ei.h>


using namespace swm;


SwmQueue::SwmQueue() {
}

SwmQueue::SwmQueue(const char* buf) {
  if (!buf) {
    std::cerr << "Cannot convert ei buffer into SwmQueue: empty" << std::endl;
    return;
  }

  int term_size = 0;
  int index = 0;

  if (ei_decode_tuple_header(buf, &index, &term_size) < 0) {
    std::cerr << "Cannot decode SwmQueue header from ei buffer" << std::endl;
    return;
  }

  if (ei_buffer_to_uint64_t(buf, index, this->id)) {
    std::cerr << "Could not initialize queue property at position=2" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->name)) {
    std::cerr << "Could not initialize queue property at position=3" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_atom(buf, index, this->state)) {
    std::cerr << "Could not initialize queue property at position=4" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->jobs)) {
    std::cerr << "Could not initialize queue property at position=5" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->nodes)) {
    std::cerr << "Could not initialize queue property at position=6" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->users)) {
    std::cerr << "Could not initialize queue property at position=7" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->admins)) {
    std::cerr << "Could not initialize queue property at position=8" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->hooks)) {
    std::cerr << "Could not initialize queue property at position=9" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_int64_t(buf, index, this->priority)) {
    std::cerr << "Could not initialize queue property at position=10" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_str(buf, index, this->comment)) {
    std::cerr << "Could not initialize queue property at position=11" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

  if (ei_buffer_to_uint64_t(buf, index, this->revision)) {
    std::cerr << "Could not initialize queue property at position=12" << std::endl;
    ei_print_term(stderr, buf, index);
    return;
  }

}



void SwmQueue::set_id(const uint64_t &new_val) {
  id = new_val;
}

void SwmQueue::set_name(const std::string &new_val) {
  name = new_val;
}

void SwmQueue::set_state(const std::string &new_val) {
  state = new_val;
}

void SwmQueue::set_jobs(const std::vector<std::string> &new_val) {
  jobs = new_val;
}

void SwmQueue::set_nodes(const std::vector<std::string> &new_val) {
  nodes = new_val;
}

void SwmQueue::set_users(const std::vector<std::string> &new_val) {
  users = new_val;
}

void SwmQueue::set_admins(const std::vector<std::string> &new_val) {
  admins = new_val;
}

void SwmQueue::set_hooks(const std::vector<std::string> &new_val) {
  hooks = new_val;
}

void SwmQueue::set_priority(const int64_t &new_val) {
  priority = new_val;
}

void SwmQueue::set_comment(const std::string &new_val) {
  comment = new_val;
}

void SwmQueue::set_revision(const uint64_t &new_val) {
  revision = new_val;
}

uint64_t SwmQueue::get_id() const {
  return id;
}

std::string SwmQueue::get_name() const {
  return name;
}

std::string SwmQueue::get_state() const {
  return state;
}

std::vector<std::string> SwmQueue::get_jobs() const {
  return jobs;
}

std::vector<std::string> SwmQueue::get_nodes() const {
  return nodes;
}

std::vector<std::string> SwmQueue::get_users() const {
  return users;
}

std::vector<std::string> SwmQueue::get_admins() const {
  return admins;
}

std::vector<std::string> SwmQueue::get_hooks() const {
  return hooks;
}

int64_t SwmQueue::get_priority() const {
  return priority;
}

std::string SwmQueue::get_comment() const {
  return comment;
}

uint64_t SwmQueue::get_revision() const {
  return revision;
}


int swm::ei_buffer_to_queue(const char* buf, const int pos, std::vector<SwmQueue> &array) {
  int term_size = 0
  int term_type = 0;
  const int parsed = ei_get_type(buf, index, &term_type, &term_size);
  if (parsed < 0) {
    std::cerr << "Could not get term type at position " << pos << std::endl;
    return -1;
  }
  if (term_type != ERL_LIST_EXT) {
      std::cerr << "Could not parse term: not a queue list at position " << pos << std::endl;
      return -1;
  }
  int list_size = 0;
  if (ei_decode_list_header(buf, &pos, &list_size) < 0) {
    std::cerr << "Could not parse list for queue at position " << pos << std::endl;
    return -1;
  }
  if (list_size == 0) {
    return 0;
  }
  array.reserve(list_size);
  for (size_t i=0; i<list_size; ++i) {
    ei_term term;
    if (ei_decode_ei_term(buf, pos, &term) < 0) {
      std::cerr << "Could not decode list element at position " << pos << std::endl;
      return -1;
    }
    array.push_back(SwmQueue(term));
  }
  return 0;
}


int swm::eterm_to_queue(char* buf, SwmQueue &obj) {
  ei_term term;
  if (ei_decode_ei_term(buf, 0, &term) < 0) {
    std::cerr << "Could not decode element for " << queue << std::endl;
    return -1;
  }
  obj = SwmQueue(eterm);
  return 0;
}


void SwmQueue::print(const std::string &prefix, const char separator) const {
    std::cerr << prefix << id << separator;
    std::cerr << prefix << name << separator;
    std::cerr << prefix << state << separator;
  if (jobs.empty()) {
    std::cerr << prefix << "jobs: []" << separator;
  } else {
    std::cerr << prefix << "jobs" << ": [";
    for (const auto &q: jobs) {
      std::cerr << q << ",";
    }
    std::cerr << "]" << separator;
  }
  if (nodes.empty()) {
    std::cerr << prefix << "nodes: []" << separator;
  } else {
    std::cerr << prefix << "nodes" << ": [";
    for (const auto &q: nodes) {
      std::cerr << q << ",";
    }
    std::cerr << "]" << separator;
  }
  if (users.empty()) {
    std::cerr << prefix << "users: []" << separator;
  } else {
    std::cerr << prefix << "users" << ": [";
    for (const auto &q: users) {
      std::cerr << q << ",";
    }
    std::cerr << "]" << separator;
  }
  if (admins.empty()) {
    std::cerr << prefix << "admins: []" << separator;
  } else {
    std::cerr << prefix << "admins" << ": [";
    for (const auto &q: admins) {
      std::cerr << q << ",";
    }
    std::cerr << "]" << separator;
  }
  if (hooks.empty()) {
    std::cerr << prefix << "hooks: []" << separator;
  } else {
    std::cerr << prefix << "hooks" << ": [";
    for (const auto &q: hooks) {
      std::cerr << q << ",";
    }
    std::cerr << "]" << separator;
  }
    std::cerr << prefix << priority << separator;
    std::cerr << prefix << comment << separator;
    std::cerr << prefix << revision << separator;
  std::cerr << std::endl;
}


