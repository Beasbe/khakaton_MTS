// src/lib/apiProjects.ts
import { ProjectItem, ApiResponse, ProjectItemResponse } from "@/types";
// Публичный URL бэкенда для браузера (вшивается при сборке через NEXT_PUBLIC_API_URL)
const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || "";
// Внутренний URL бэкенда для серверных запросов (SSR): из контейнера фронтенда
// localhost:<NodePort> недоступен — сервер ходит напрямую в Service waf (вариант A).
const INTERNAL_API_BASE_URL =
  process.env.BACKEND_INTERNAL_API_URL || process.env.API_URL || "";
const API_TIMEOUT = 5000;

// На сервере (SSR) — внутренний адрес, в браузере — публичный.
function apiBaseUrl(): string {
  if (typeof window === "undefined" && INTERNAL_API_BASE_URL) {
    return INTERNAL_API_BASE_URL;
  }
  return API_BASE_URL;
}

// Универсальная функция fetch с таймаутом
async function fetchWithTimeout(
  url: string,
  options: RequestInit = {},
  timeout = API_TIMEOUT,
) {
  const controller = new AbortController();
  const id = setTimeout(() => controller.abort(), timeout);

  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        ...options.headers,
      },
    });
    clearTimeout(id);
    return response;
  } catch (error) {
    clearTimeout(id);
    throw error;
  }
}

// ==================== PROJECTS API ====================

/**
 * Получить список проектов с фильтрацией и пагинацией
 */
export async function getProjectsFromBackend(params?: {
  category?: string;
  year?: string;
  search?: string;
  page?: number;
  per_page?: number;
}): Promise<{ data: ProjectItem[]; meta: any }> {
  try {
    const queryParams = new URLSearchParams();

    if (params?.category) queryParams.append("category", params.category);
    if (params?.year) queryParams.append("year", params.year);
    if (params?.search) queryParams.append("search", params.search);
    if (params?.page) queryParams.append("page", params.page.toString());
    if (params?.per_page)
      queryParams.append("per_page", params.per_page.toString());

    const queryString = queryParams.toString();
    const url = `${apiBaseUrl()}/api/projects${queryString ? `?${queryString}` : ""}`;

    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: ApiResponse<ProjectItem[]> = await response.json();

    if (result.success && result.data) {
      return {
        data: result.data.map((item: any) => ({
          id: item.id,
          slug: item.slug,
          title: item.title,
          short_description: item.short_description,
          full_description: item.full_description,
          year: item.year,
          location: item.location || "",
          category: item.category,
          client: item.client || "",
          duration: item.duration || "",
          technologies: item.technologies || [],
          challenges: item.challenges || [],
          results: item.results || [],
          image: item.image ? `${API_BASE_URL}/storage/${item.image}` : null,
          featured: Boolean(item.featured),
          is_published: Boolean(item.is_published),
          sort_order: item.sort_order || 0,
          created_at: item.created_at,
          updated_at: item.updated_at,
        })),
        meta: result.meta || {
          total: result.data.length,
          last_page: 1,
          current_page: 1,
          per_page: params?.per_page || 10,
        },
      };
    }

    throw new Error(result.error || "Не удалось получить данные");
  } catch (error) {
    console.warn("Не удалось получить проекты с бэкенда:", error);
    throw error;
  }
}

/**
 * Получить один проект по slug
 */
export async function getProjectItemFromBackend(
  slug: string,
): Promise<ProjectItemResponse | null> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/${slug}`,
    );

    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return {
        data: {
          id: result.data.id,
          slug: result.data.slug,
          title: result.data.title,
          short_description: result.data.short_description,
          full_description: result.data.full_description,
          year: result.data.year,
          location: result.data.location || "",
          category: result.data.category,
          client: result.data.client || "",
          duration: result.data.duration || "",
          technologies: result.data.technologies || [],
          challenges: result.data.challenges || [],
          results: result.data.results || [],
          image: result.data.image
            ? `${API_BASE_URL}/storage/${result.data.image}`
            : null,
          featured: Boolean(result.data.featured),
          is_published: Boolean(result.data.is_published),
          sort_order: result.data.sort_order || 0,
          created_at: result.data.created_at,
          updated_at: result.data.updated_at,
        },
        related:
          result.related?.map((item: any) => ({
            id: item.id,
            slug: item.slug,
            title: item.title,
            short_description: item.short_description,
            full_description: item.full_description,
            year: item.year,
            location: item.location || "",
            category: item.category,
            client: item.client || "",
            duration: item.duration || "",
            technologies: item.technologies || [],
            challenges: item.challenges || [],
            results: item.results || [],
            image: item.image ? `${API_BASE_URL}/storage/${item.image}` : null,
            featured: Boolean(item.featured),
            is_published: Boolean(item.is_published),
            sort_order: item.sort_order || 0,
            created_at: item.created_at,
            updated_at: item.updated_at,
          })) || [],
      };
    }

    return null;
  } catch (error) {
    console.warn(`Не удалось получить проект ${slug} с бэкенда:`, error);
    throw error;
  }
}

/**
 * Получить список категорий проектов
 */
export async function getProjectCategoriesFromBackend(): Promise<string[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/categories`,
    );

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data;
    }

    return [];
  } catch (error) {
    console.warn("Не удалось получить категории проектов с бэкенда:", error);
    return [];
  }
}

/**
 * Получить список годов проектов
 */
export async function getProjectYearsFromBackend(): Promise<number[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/years`,
    );

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data;
    }

    return [];
  } catch (error) {
    console.warn("Не удалось получить годы проектов с бэкенда:", error);
    return [];
  }
}

/**
 * Получить избранные проекты
 */
export async function getFeaturedProjectsFromBackend(
  limit: number = 6,
): Promise<ProjectItem[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/featured/${limit}`,
    );

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data.map((item: any) => ({
        id: item.id,
        slug: item.slug,
        title: item.title,
        short_description: item.short_description,
        full_description: item.full_description,
        year: item.year,
        location: item.location || "",
        category: item.category,
        client: item.client || "",
        duration: item.duration || "",
        technologies: item.technologies || [],
        challenges: item.challenges || [],
        results: item.results || [],
        image: item.image ? `${API_BASE_URL}/storage/${item.image}` : null,
        featured: Boolean(item.featured),
        is_published: Boolean(item.is_published),
        sort_order: item.sort_order || 0,
        created_at: item.created_at,
        updated_at: item.updated_at,
      }));
    }

    return [];
  } catch (error) {
    console.warn("Не удалось получить избранные проекты с бэкенда:", error);
    return [];
  }
}

/**
 * Получить проекты по категории
 */
export async function getProjectsByCategoryFromBackend(
  category: string,
  limit: number = 6,
): Promise<ProjectItem[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/category/${category}/${limit}`,
    );

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data.map((item: any) => ({
        id: item.id,
        slug: item.slug,
        title: item.title,
        short_description: item.short_description,
        full_description: item.full_description,
        year: item.year,
        location: item.location || "",
        category: item.category,
        client: item.client || "",
        duration: item.duration || "",
        technologies: item.technologies || [],
        challenges: item.challenges || [],
        results: item.results || [],
        image: item.image ? `${API_BASE_URL}/storage/${item.image}` : null,
        featured: Boolean(item.featured),
        is_published: Boolean(item.is_published),
        sort_order: item.sort_order || 0,
        created_at: item.created_at,
        updated_at: item.updated_at,
      }));
    }

    return [];
  } catch (error) {
    console.warn(
      `Не удалось получить проекты категории ${category} с бэкенда:`,
      error,
    );
    return [];
  }
}

/**
 * Проверить доступность бэкенда
 */
export async function checkBackendAvailability(): Promise<boolean> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/projects/featured/1`,
      {},
      3000,
    );
    return response.ok;
  } catch {
    return false;
  }
}
