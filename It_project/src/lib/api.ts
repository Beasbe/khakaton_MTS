import { NewsItem, ApiResponse, NewsItemResponse } from "@/types";
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

export async function getNewsFromBackend(params?: {
  category?: string;
  year?: string;
  search?: string;
  page?: number;
  per_page?: number;
}): Promise<{ data: NewsItem[]; meta: any }> {
  try {
    const queryParams = new URLSearchParams();
    if (params?.category) queryParams.append("category", params.category);
    if (params?.year) queryParams.append("year", params.year);
    if (params?.search) queryParams.append("search", params.search);
    if (params?.page) queryParams.append("page", params.page.toString());
    if (params?.per_page)
      queryParams.append("per_page", params.per_page.toString());

    const queryString = queryParams.toString();
    const url = `${apiBaseUrl()}/api/news${queryString ? `?${queryString}` : ""}`;

    const response = await fetchWithTimeout(url);

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: ApiResponse<NewsItem[]> = await response.json();

    if (result.success && result.data) {
      return {
        data: result.data.map((item: any) => ({
          id: item.id,
          title: item.title,
          excerpt: item.excerpt,
          content: item.content,
          category: item.category,
          date: item.date,
          year: item.year,
          featured: Boolean(item.featured),
          image: item.image_url
            ? `${API_BASE_URL}/storage/${item.image_url}`
            : item.image
              ? `${API_BASE_URL}/storage/${item.image}`
              : null,
          slug: item.slug,
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
    console.warn("Не удалось получить новости с бэкенда:", error);
    throw error;
  }
}

export async function getNewsItemFromBackend(
  slug: string,
): Promise<NewsItemResponse | null> {
  try {
    const response = await fetchWithTimeout(`${apiBaseUrl()}/api/news/${slug}`);

    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return {
        data: {
          id: result.data.id,
          title: result.data.title,
          excerpt: result.data.excerpt,
          content: result.data.content,
          category: result.data.category,
          date: result.data.date,
          year: result.data.year,
          featured: Boolean(result.data.featured),
          image: result.data.image
            ? `${API_BASE_URL}/storage/${result.data.image}`
            : null,
          slug: result.data.slug,
          created_at: result.data.created_at,
          updated_at: result.data.updated_at,
        },
        related: {
          previous: result.related?.previous
            ? {
                id: result.related.previous.id,
                title: result.related.previous.title,
                excerpt: result.related.previous.excerpt,
                content: result.related.previous.content,
                category: result.related.previous.category,
                date: result.related.previous.date,
                year: result.related.previous.year,
                featured: Boolean(result.related.previous.featured),
                image: result.related.previous.image
                  ? `${API_BASE_URL}/storage/${result.related.previous.image}`
                  : null,
                slug: result.related.previous.slug,
                created_at: result.related.previous.created_at,
                updated_at: result.related.previous.updated_at,
              }
            : null,
          next: result.related?.next
            ? {
                id: result.related.next.id,
                title: result.related.next.title,
                excerpt: result.related.next.excerpt,
                content: result.related.next.content,
                category: result.related.next.category,
                date: result.related.next.date,
                year: result.related.next.year,
                featured: Boolean(result.related.next.featured),
                image: result.related.next.image
                  ? `${API_BASE_URL}/storage/${result.related.next.image}`
                  : null,
                slug: result.related.next.slug,
                created_at: result.related.next.created_at,
                updated_at: result.related.next.updated_at,
              }
            : null,
        },
      };
    }

    return null;
  } catch (error) {
    console.warn(`Не удалось получить новость ${slug} с бэкенда:`, error);
    throw error;
  }
}

export async function getNewsCategoriesFromBackend(): Promise<string[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/news/categories`,
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
    console.warn("Не удалось получить категории новостей с бэкенда:", error);
    return [];
  }
}

export async function getNewsYearsFromBackend(): Promise<number[]> {
  try {
    const response = await fetchWithTimeout(`${apiBaseUrl()}/api/news/years`);

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data;
    }

    return [];
  } catch (error) {
    console.warn("Не удалось получить годы новостей с бэкенда:", error);
    return [];
  }
}

export async function getLatestNewsFromBackend(
  limit: number = 5,
): Promise<NewsItem[]> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/news/latest/${limit}`,
    );

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const result: any = await response.json();

    if (result.success && result.data) {
      return result.data.map((item: any) => ({
        id: item.id,
        title: item.title,
        excerpt: item.excerpt,
        content: item.content,
        category: item.category,
        date: item.date,
        year: item.year,
        featured: Boolean(item.featured),
        image: item.image ? `${API_BASE_URL}/storage/${item.image}` : null,
        slug: item.slug,
        created_at: item.created_at,
        updated_at: item.updated_at,
      }));
    }

    return [];
  } catch (error) {
    console.warn("Не удалось получить последние новости с бэкенда:", error);
    return [];
  }
}

export async function checkBackendAvailability(): Promise<boolean> {
  try {
    const response = await fetchWithTimeout(
      `${apiBaseUrl()}/api/news/latest/1`,
      {},
      3000,
    );
    return response.ok;
  } catch {
    return false;
  }
}
