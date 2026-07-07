package com.example.docker_optimization_showcase.api;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
class InfoControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void contextLoads() {
        // Verifica che il contesto Spring carichi correttamente
        assertThat(mockMvc).isNotNull();
    }

    @Test
    void getInfoReturnsCorrectFields() throws Exception {
        // Esegue la richiesta GET su /api/info
        mockMvc.perform(get("/api/v1/info"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.app").isString())
                .andExpect(jsonPath("$.version").isString())
                .andExpect(jsonPath("$.javaVersion").isString())
                .andExpect(jsonPath("$.hostname").isString())
                .andExpect(jsonPath("$.uptimeSeconds").exists());
    }
}
